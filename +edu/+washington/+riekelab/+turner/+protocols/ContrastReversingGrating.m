classdef ContrastReversingGrating < edu.washington.riekelab.protocols.RiekeLabStageProtocol

    properties
        preTime = 250 % ms
        stimTime = 2000 % ms
        tailTime = 250 % ms
        contrast = [0.9] % relative to mean (0-1); row array
        temporalFrequency = 4 % Hz
        apertureDiameter = 300; % um
        maskDiameter = 0; % um
        barWidth = [5 10 20 40 80 160] % um
        rotation = 0; % deg
        backgroundIntensity = 0.5 % (0-1)
        randomizeOrder = false;
        onlineAnalysis = 'none'
        numberOfAverages = uint16(20) % total number of epochs to queue
        amp
    end

    properties (Hidden)
        ampType
        contrastType = symphonyui.core.PropertyType('denserealdouble', 'row')
        barWidthType = symphonyui.core.PropertyType('denserealdouble', 'row')

        onlineAnalysisType = symphonyui.core.PropertyType('char', 'row', {'none', 'extracellular', 'exc', 'inh'})
        conditionSequence
        currentBarWidth
        currentContrast
    end

    properties (Hidden, Transient)
        analysisFigure
        f2ByContrastFigure
    end

    methods

        function didSetRig(obj)
            didSetRig@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj);
            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end

        function prepareRun(obj)
            prepareRun@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj);

            % Treat every bar-width/contrast pair as a separate condition.
            [bwGrid, contrastGrid] = ndgrid(obj.barWidth, obj.contrast);
            obj.conditionSequence = [bwGrid(:), contrastGrid(:)];

            nConditions = size(obj.conditionSequence, 1);
            if nConditions > 1
                colors = edu.washington.riekelab.turner.utils.pmkmp(nConditions, 'CubicYF');
            else
                colors = [0 0 0];
            end

            obj.showFigure('symphonyui.builtin.figures.ResponseFigure', ...
                obj.rig.getDevice(obj.amp));

            obj.showFigure('edu.washington.riekelab.turner.figures.MeanResponseFigure', ...
                obj.rig.getDevice(obj.amp), ...
                'recordingType', obj.onlineAnalysis, ...
                'groupBy', {'currentBarWidth', 'currentContrast'}, ...
                'sweepColor', colors);

            obj.showFigure('edu.washington.riekelab.turner.figures.FrameTimingFigure', ...
                obj.rig.getDevice('Stage'), obj.rig.getDevice('Frame Monitor'));

            if ~strcmp(obj.onlineAnalysis, 'none')
                % Existing F1/F2 figure, now tracked independently for
                % every (bar width, contrast) condition.
                if isempty(obj.analysisFigure) || ~isvalid(obj.analysisFigure)
                    obj.analysisFigure = obj.showFigure( ...
                        'symphonyui.builtin.figures.CustomFigure', @obj.CRGanalysis);
                    f = obj.analysisFigure.getFigureHandle();
                    set(f, 'Name', 'CRGs');
                    obj.analysisFigure.userData.trialCounts = zeros(numel(obj.barWidth), numel(obj.contrast));
                    obj.analysisFigure.userData.F1 = zeros(numel(obj.barWidth), numel(obj.contrast));
                    obj.analysisFigure.userData.F2 = zeros(numel(obj.barWidth), numel(obj.contrast));
                    obj.analysisFigure.userData.axesHandle = axes('Parent', f);
                else
                    obj.analysisFigure.userData.trialCounts = zeros(numel(obj.barWidth), numel(obj.contrast));
                    obj.analysisFigure.userData.F1 = zeros(numel(obj.barWidth), numel(obj.contrast));
                    obj.analysisFigure.userData.F2 = zeros(numel(obj.barWidth), numel(obj.contrast));
                end

                % Additional figure: F2 vs bar width, one overlaid trace per contrast.
                ampDevice = obj.rig.getDevice(obj.amp);
                recordingType = obj.onlineAnalysis;
                tf = obj.temporalFrequency;
                preMs = obj.preTime;
                stimMs = obj.stimTime;
                widths = obj.barWidth;
                contrasts = obj.contrast;

                obj.f2ByContrastFigure = obj.showFigure( ...
                    'symphonyui.builtin.figures.CustomFigure', ...
                    @(fig, epoch) edu.washington.riekelab.turner.figures.F2ByContrastFigure( ...
                        fig, epoch, ampDevice, recordingType, tf, preMs, stimMs, widths, contrasts));
                f2f = obj.f2ByContrastFigure.getFigureHandle();
                set(f2f, 'Name', 'CRG F2 by contrast');
            end
        end

        function CRGanalysis(obj, ~, epoch) % online analysis function
            response = epoch.getResponse(obj.rig.getDevice(obj.amp));
            epochResponseTrace = response.getData();
            sampleRate = response.sampleRate.quantityInBaseUnits;

            axesHandle = obj.analysisFigure.userData.axesHandle;
            trialCounts = obj.analysisFigure.userData.trialCounts;
            F1 = obj.analysisFigure.userData.F1;
            F2 = obj.analysisFigure.userData.F2;

            if strcmp(obj.onlineAnalysis, 'extracellular') % spike recording
                epochResponseTrace = epochResponseTrace( ...
                    (sampleRate*obj.preTime/1000)+1 : ...
                    (sampleRate*(obj.preTime + obj.stimTime)/1000));
                S = edu.washington.riekelab.turner.utils.spikeDetectorOnline(epochResponseTrace);
                epochResponseTrace = zeros(size(epochResponseTrace));
                epochResponseTrace(S.sp) = 1; % spike binary
            else % intracellular - Vclamp
                epochResponseTrace = epochResponseTrace - ...
                    mean(epochResponseTrace(1:sampleRate*obj.preTime/1000));
                epochResponseTrace = epochResponseTrace( ...
                    (sampleRate*obj.preTime/1000)+1 : ...
                    (sampleRate*(obj.preTime + obj.stimTime)/1000));
            end

            L = length(epochResponseTrace);
            X = abs(fft(epochResponseTrace));
            X = X(1:L/2);
            f = sampleRate*(0:L/2-1)/L;
            [~, F1ind] = min(abs(f-obj.temporalFrequency));
            [~, F2ind] = min(abs(f-2*obj.temporalFrequency));

            F1power = 2*X(F1ind);
            F2power = 2*X(F2ind);

            % Index by BOTH bar width and contrast. Use epoch parameters
            % because later epochs may already have been prepared by Symphony.
            currentBarWidth = epoch.parameters('currentBarWidth');
            currentContrast = epoch.parameters('currentContrast');
            barInd = find(currentBarWidth == obj.barWidth, 1);
            contrastInd = find(currentContrast == obj.contrast, 1);

            if isempty(barInd) || isempty(contrastInd)
                return;
            end

            trialCounts(barInd, contrastInd) = trialCounts(barInd, contrastInd) + 1;
            F1(barInd, contrastInd) = F1(barInd, contrastInd) + F1power;
            F2(barInd, contrastInd) = F2(barInd, contrastInd) + F2power;

            meanF1 = F1 ./ trialCounts;
            meanF2 = F2 ./ trialCounts;
            meanF1(trialCounts == 0) = NaN;
            meanF2(trialCounts == 0) = NaN;

            cla(axesHandle);
            hold(axesHandle, 'on');

            if numel(obj.contrast) > 1
                colors = edu.washington.riekelab.turner.utils.pmkmp(numel(obj.contrast), 'CubicYF');
                lineHandles = gobjects(1, 2*numel(obj.contrast));
                legendText = cell(1, 2*numel(obj.contrast));

                for ii = 1:numel(obj.contrast)
                    lineHandles(2*ii-1) = line(obj.barWidth, meanF1(:, ii), ...
                        'Parent', axesHandle, 'Color', colors(ii,:), ...
                        'LineWidth', 1.5, 'LineStyle', '--', 'Marker', 'o');
                    lineHandles(2*ii) = line(obj.barWidth, meanF2(:, ii), ...
                        'Parent', axesHandle, 'Color', colors(ii,:), ...
                        'LineWidth', 2, 'LineStyle', '-', 'Marker', 'o');
                    legendText{2*ii-1} = sprintf('F1, C=%.3g', obj.contrast(ii));
                    legendText{2*ii} = sprintf('F2, C=%.3g', obj.contrast(ii));
                end
                legend(axesHandle, lineHandles, legendText, 'Location', 'best');
            else
                h1 = line(obj.barWidth, meanF1(:,1), 'Parent', axesHandle);
                set(h1, 'Color', 'g', 'LineWidth', 2, 'Marker', 'o');
                h2 = line(obj.barWidth, meanF2(:,1), 'Parent', axesHandle);
                set(h2, 'Color', 'r', 'LineWidth', 2, 'Marker', 'o');
                legend(axesHandle, {'F1', 'F2'});
            end

            hold(axesHandle, 'off');
            xlabel(axesHandle, 'Bar width (um)');
            ylabel(axesHandle, 'Amplitude');

            obj.analysisFigure.userData.trialCounts = trialCounts;
            obj.analysisFigure.userData.F1 = F1;
            obj.analysisFigure.userData.F2 = F2;
        end

        function p = createPresentation(obj)
            canvasSize = obj.rig.getDevice('Stage').getCanvasSize();

            % convert from microns to pixels...
            apertureDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.apertureDiameter);
            maskDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.maskDiameter);
            currentBarWidthPix = obj.rig.getDevice('Stage').um2pix(obj.currentBarWidth);

            p = stage.core.Presentation((obj.preTime + obj.stimTime + obj.tailTime) * 1e-3);
            p.setBackgroundColor(obj.backgroundIntensity);

            % Create grating stimulus.
            grate = stage.builtin.stimuli.Grating('square');
            grate.orientation = obj.rotation;
            grate.size = [apertureDiameterPix, apertureDiameterPix];
            grate.position = canvasSize/2;
            grate.spatialFreq = 1/(2*currentBarWidthPix);
            grate.color = 2*obj.backgroundIntensity;

            % Calculate phase shift so a contrast-reversing boundary is in
            % the center regardless of spatial frequency.
            zeroCrossings = 0:(grate.spatialFreq^-1):grate.size(1);
            offsets = zeroCrossings-grate.size(1)/2;
            [shiftPix, ~] = min(offsets(offsets>0));
            phaseShift_rad = (shiftPix/(grate.spatialFreq^-1))*(2*pi);
            phaseShift = 360*(phaseShift_rad)/(2*pi);
            grate.phase = phaseShift;
            p.addStimulus(grate);

            % Make it contrast-reversing.
            if obj.temporalFrequency > 0
                grateContrast = stage.builtin.controllers.PropertyController( ...
                    grate, 'contrast', ...
                    @(state)getGrateContrast(obj, state.time - obj.preTime/1e3));
                p.addController(grateContrast);
            end

            function c = getGrateContrast(obj, time)
                % currentContrast is scalar even when obj.contrast is an array.
                c = obj.currentContrast .* sin(2*pi*obj.temporalFrequency*time);
            end

            if obj.apertureDiameter > 0
                aperture = stage.builtin.stimuli.Rectangle();
                aperture.position = canvasSize/2;
                aperture.color = obj.backgroundIntensity;
                aperture.size = [apertureDiameterPix, apertureDiameterPix];
                mask = stage.core.Mask.createCircularAperture(1, 1024);
                aperture.setMask(mask);
                p.addStimulus(aperture);
            end

            if obj.maskDiameter > 0
                mask = stage.builtin.stimuli.Ellipse();
                mask.position = canvasSize/2;
                mask.color = obj.backgroundIntensity;
                mask.radiusX = maskDiameterPix/2;
                mask.radiusY = maskDiameterPix/2;
                p.addStimulus(mask);
            end

            % Hide during pre & post.
            grateVisible = stage.builtin.controllers.PropertyController( ...
                grate, 'visible', ...
                @(state) state.time >= obj.preTime*1e-3 && ...
                    state.time < (obj.preTime + obj.stimTime)*1e-3);
            p.addController(grateVisible);
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj, epoch);

            device = obj.rig.getDevice(obj.amp);
            duration = (obj.preTime + obj.stimTime + obj.tailTime) / 1e3;
            epoch.addDirectCurrentStimulus(device, device.background, duration, obj.sampleRate);
            epoch.addResponse(device);

            nConditions = size(obj.conditionSequence, 1);
            index = mod(obj.numEpochsCompleted, nConditions) + 1;

            % Randomize complete (barWidth, contrast) pairs at the beginning
            % of each condition block.
            if index == 1 && obj.randomizeOrder
                order = randperm(nConditions);
                obj.conditionSequence = obj.conditionSequence(order, :);
            end

            obj.currentBarWidth = obj.conditionSequence(index, 1);
            obj.currentContrast = obj.conditionSequence(index, 2);

            % Bar greater than 1/2 aperture size -> split-field grating.
            if obj.currentBarWidth > obj.apertureDiameter/2
                obj.currentBarWidth = obj.apertureDiameter/2;
            end

            epoch.addParameter('currentBarWidth', obj.currentBarWidth);
            epoch.addParameter('currentContrast', obj.currentContrast);
        end

        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages;
        end

        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages;
        end

    end

end
