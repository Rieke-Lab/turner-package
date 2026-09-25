function F2ByContrastFigure(figureHandler, epoch, device, recordingType, ...
    temporalFrequency, preTime, stimTime, barWidths, contrasts)
%F2BYCONTRASTFIGURE Online CRG analysis: F2 vs bar width by contrast.
%
% Intended for use with symphonyui.builtin.figures.CustomFigure.
%
% For each epoch:
%   - calculates F2 amplitude
%   - accumulates responses independently for each
%     (bar width, contrast) condition
%   - averages across repeats
%   - plots one F2-vs-bar-width curve for each contrast
%
% No normalization is applied.

    response = epoch.getResponse(device);
    trace = response.getData();
    sampleRate = response.sampleRate.quantityInBaseUnits;

    currentBarWidth = epoch.parameters('currentBarWidth');
    currentContrast = epoch.parameters('currentContrast');

    % -------------------------------------------------------------
    % Initialize persistent figure state
    % -------------------------------------------------------------
    if ~isfield(figureHandler.userData, 'axesHandle') || ...
            isempty(figureHandler.userData.axesHandle) || ...
            ~isgraphics(figureHandler.userData.axesHandle)

        f = figureHandler.getFigureHandle();

        figureHandler.userData.axesHandle = axes('Parent', f);

        figureHandler.userData.trialCounts = ...
            zeros(numel(barWidths), numel(contrasts));

        figureHandler.userData.F2 = ...
            zeros(numel(barWidths), numel(contrasts));
    end

    axesHandle = figureHandler.userData.axesHandle;
    trialCounts = figureHandler.userData.trialCounts;
    F2 = figureHandler.userData.F2;

    % -------------------------------------------------------------
    % Convert timing to sample points
    % -------------------------------------------------------------
    prePts = round(sampleRate * preTime / 1000);
    stimPts = round(sampleRate * stimTime / 1000);

    % -------------------------------------------------------------
    % Preprocess response
    % -------------------------------------------------------------
    if strcmp(recordingType, 'extracellular')

        % Take stimulus period only.
        trace = trace(prePts + 1 : prePts + stimPts);

        % Detect spikes.
        S = edu.washington.riekelab.turner.utils.spikeDetectorOnline(trace);

        % Convert to binary spike train.
        binaryTrace = zeros(size(trace));
        binaryTrace(S.sp) = 1;

        trace = binaryTrace;

    else

        % Intracellular recording:
        % subtract baseline measured during preTime.
        baseline = mean(trace(1:prePts));
        trace = trace - baseline;

        % Take stimulus period only.
        trace = trace(prePts + 1 : prePts + stimPts);

    end

    % -------------------------------------------------------------
    % FFT and F2 amplitude
    % -------------------------------------------------------------
    L = length(trace);

    X = abs(fft(trace));

    % Keep positive-frequency half.
    X = X(1:floor(L/2));

    f = sampleRate * (0:numel(X)-1) / L;

    % Find F2 = 2 * temporal frequency.
    [~, F2ind] = min(abs(f - 2 * temporalFrequency));

    % Match the amplitude convention used in the original protocol.
    F2power = 2 * X(F2ind);

    % -------------------------------------------------------------
    % Find current condition
    % -------------------------------------------------------------
    barInd = find(barWidths == currentBarWidth, 1);
    contrastInd = find(contrasts == currentContrast, 1);

    if isempty(barInd) || isempty(contrastInd)
        return;
    end

    % -------------------------------------------------------------
    % Accumulate response
    % -------------------------------------------------------------
    trialCounts(barInd, contrastInd) = ...
        trialCounts(barInd, contrastInd) + 1;

    F2(barInd, contrastInd) = ...
        F2(barInd, contrastInd) + F2power;

    % -------------------------------------------------------------
    % Compute mean response
    % -------------------------------------------------------------
    meanF2 = F2 ./ trialCounts;

    % Conditions not yet sampled should not appear as zero.
    meanF2(trialCounts == 0) = NaN;

    % -------------------------------------------------------------
    % Plot
    % -------------------------------------------------------------
    cla(axesHandle);
    hold(axesHandle, 'on');

    % One color per contrast.
    if numel(contrasts) > 1

        colors = ...
            edu.washington.riekelab.turner.utils.pmkmp( ...
            numel(contrasts), 'CubicYF');

    else

        colors = [0 0 0];

    end

    lineHandles = gobjects(1, numel(contrasts));
    legendText = cell(1, numel(contrasts));

    for ii = 1:numel(contrasts)

        f2Curve = meanF2(:, ii);

        lineHandles(ii) = line( ...
            barWidths, ...
            f2Curve, ...
            'Parent', axesHandle, ...
            'Color', colors(ii, :), ...
            'LineWidth', 2, ...
            'Marker', 'o');

        legendText{ii} = sprintf( ...
            'Contrast %.3g', contrasts(ii));

    end

    hold(axesHandle, 'off');

    % -------------------------------------------------------------
    % Figure formatting
    % -------------------------------------------------------------
    xlabel(axesHandle, 'Bar width (um)');
    ylabel(axesHandle, 'F2 amplitude');

    title(axesHandle, ...
        sprintf('F2 at %.3g Hz', 2 * temporalFrequency));

    legend(axesHandle, ...
        lineHandles, ...
        legendText, ...
        'Location', 'best');

    % -------------------------------------------------------------
    % Save updated running analysis
    % -------------------------------------------------------------
    figureHandler.userData.trialCounts = trialCounts;
    figureHandler.userData.F2 = F2;

end