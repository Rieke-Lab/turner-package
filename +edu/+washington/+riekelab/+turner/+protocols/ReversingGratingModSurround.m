classdef ReversingGratingModSurround < edu.washington.riekelab.protocols.RiekeLabStageProtocol

    properties
        preTime = 250 % ms
        stimTime = 2000 % ms
        tailTime = 250 % ms
        
        temporalFrequency = 2 % Hz
        maskDiameter = 0; % um
        barWidth = [5 10 20 40 80 160] % um
        rotation = 0; % deg
        randomizeOrder = false;
        
        apertureDiameter = 330 % um
        annulusInnerDiameter = 500; %  um
        annulusOuterDiameter = 900; % um
        surroundContrast = [-0.95 -0.5 0 0.5 1 2.5];
        gratingContrast = 1;
        backgroundIntensity = 0.5; %0-1
        
        onlineAnalysis = 'none'
        amp % Output amplifier
        numberOfAverages = uint16(3) % number of epochs to queue
    end
    
    properties (Hidden)
        ampType
        onlineAnalysisType = symphonyui.core.PropertyType('char', 'row', {'none', 'extracellular', 'exc', 'inh'})
        stimSequence
        
        %saved out to each epoch...
        currentSurroundContrast
        currentBarWidth
    end
    
    properties (Hidden, Transient)
        analysisFigure
    end

    methods
        
        function didSetRig(obj)
            didSetRig@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj);
            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end

        function prepareRun(obj)
            prepareRun@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj);
            
            % Create surround contrast sequence.
            obj.stimSequence = [];
            for aa = 1:length(obj.surroundContrast);
                currSurr = obj.surroundContrast(aa);
                holdSeq = (ones(size(obj.barWidth)).* currSurr)';
                obj.stimSequence = [obj.stimSequence; obj.barWidth', holdSeq];
            end
            obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));
            %{
             %}
            if length(obj.stimSequence) > 1
                colors = edu.washington.riekelab.turner.utils.pmkmp(length(obj.stimSequence),'CubicYF');
            else
                colors = [0 0 0];
            end
            obj.showFigure('edu.washington.riekelab.turner.figures.MeanResponseFigure',...
                obj.rig.getDevice(obj.amp),'recordingType',obj.onlineAnalysis,...
                'groupBy',{'currentSurroundContrast','currentBarWidth'},...
                'sweepColor',colors);
            obj.showFigure('edu.washington.riekelab.turner.figures.FrameTimingFigure',...
                obj.rig.getDevice('Stage'), obj.rig.getDevice('Frame Monitor'));
            %{
            responseDimensions = [2, length(obj.surroundContrast), 1]; %image/equiv by surround contrast by grating (1)
                obj.showFigure('edu.washington.riekelab.turner.figures.ModImageVsIntensityFigure',...
                obj.rig.getDevice(obj.amp),responseDimensions,...
                'recordingType',obj.onlineAnalysis,...
                'preTime',obj.preTime,'stimTime',obj.stimTime,...
                'stimType','grating');
            %}
            
            if ~strcmp(obj.onlineAnalysis,'none')
                % custom figure handler
                if isempty(obj.analysisFigure) || ~isvalid(obj.analysisFigure)
                    obj.analysisFigure = obj.showFigure('symphonyui.builtin.figures.CustomFigure', @obj.CRGanalysis);
                    f = obj.analysisFigure.getFigureHandle();
                    set(f, 'Name', 'CRGs');
                    obj.analysisFigure.userData.trialCounts = zeros(size(obj.barWidth));
                    obj.analysisFigure.userData.F1 = zeros(size(obj.barWidth));
                    obj.analysisFigure.userData.F2 = zeros(size(obj.barWidth));
                    obj.analysisFigure.userData.axesHandle = axes('Parent', f);
                else
                    obj.analysisFigure.userData.trialCounts = zeros(size(obj.barWidth));
                    obj.analysisFigure.userData.F1 = zeros(size(obj.barWidth));
                    obj.analysisFigure.userData.F2 = zeros(size(obj.barWidth));
                end
                
            end
            
        end
        
        function CRGanalysis(obj, ~, epoch) %online analysis function
            response = epoch.getResponse(obj.rig.getDevice(obj.amp));
            epochResponseTrace = response.getData();
            sampleRate = response.sampleRate.quantityInBaseUnits;
            
            axesHandle = obj.analysisFigure.userData.axesHandle;
            trialCounts = obj.analysisFigure.userData.trialCounts;
            F1 = obj.analysisFigure.userData.F1;
            F2 = obj.analysisFigure.userData.F2;
            
            if strcmp(obj.onlineAnalysis,'extracellular') %spike recording
                %take (prePts+1:prePts+stimPts)
                epochResponseTrace = epochResponseTrace((sampleRate*obj.preTime/1000)+1:(sampleRate*(obj.preTime + obj.stimTime)/1000));
                %count spikes
                S = edu.washington.riekelab.turner.utils.spikeDetectorOnline(epochResponseTrace);
                epochResponseTrace = zeros(size(epochResponseTrace));
                epochResponseTrace(S.sp) = 1; %spike binary
                
            else %intracellular - Vclamp
                epochResponseTrace = epochResponseTrace-mean(epochResponseTrace(1:sampleRate*obj.preTime/1000)); %baseline
                %take (prePts+1:prePts+stimPts)
                epochResponseTrace = epochResponseTrace((sampleRate*obj.preTime/1000)+1:(sampleRate*(obj.preTime + obj.stimTime)/1000));
            end

            L = length(epochResponseTrace); %length of signal, datapoints
            X = abs(fft(epochResponseTrace));
            X = X(1:L/2);
            f = sampleRate*(0:L/2-1)/L; %freq - hz
            [~, F1ind] = min(abs(f-obj.temporalFrequency)); %find index of F1 and F2 frequencies
            [~, F2ind] = min(abs(f-2*obj.temporalFrequency));

            F1power = 2*X(F1ind); %pA^2/Hz for current rec, (spikes/sec)^2/Hz for spike rate
            F2power = 2*X(F2ind); %double b/c of symmetry about zero
            
            barInd = find(obj.currentBarWidth == obj.barWidth);
            trialCounts(barInd) = trialCounts(barInd) + 1;
            F1(barInd) = F1(barInd) + F1power;
            F2(barInd) = F2(barInd) + F2power;
            
            cla(axesHandle);
            h1 = line(obj.barWidth, F1./trialCounts, 'Parent', axesHandle);
            set(h1,'Color','g','LineWidth',2,'Marker','o');
            h2 = line(obj.barWidth, F2./trialCounts, 'Parent', axesHandle);
            set(h2,'Color','r','LineWidth',2,'Marker','o');
            hl = legend(axesHandle,{'F1','F2'});
            xlabel(axesHandle,'Bar width (um)')
            ylabel(axesHandle,'Amplitude')

            obj.analysisFigure.userData.trialCounts = trialCounts;
            obj.analysisFigure.userData.F1 = F1;
            obj.analysisFigure.userData.F2 = F2;
        end

        function prepareEpoch(obj, epoch)
            prepareEpoch@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj, epoch);
            device = obj.rig.getDevice(obj.amp);
            duration = (obj.preTime + obj.stimTime + obj.tailTime) / 1e3;
            epoch.addDirectCurrentStimulus(device, device.background, duration, obj.sampleRate);
            epoch.addResponse(device);
                      
           pulseNum = mod(obj.numEpochsCompleted, length(obj.stimSequence)) + 1; %pulseNumber is a rotating index through the stimSequence
            % Randomize the spot size sequence order at the beginning of each sequence.
            
            if pulseNum == 1 && obj.randomizeOrder
                totPermSize = size(obj.stimSequence);
                randInd = randperm(totPermSize(1));
                obj.stimSequence = obj.stimSequence(randInd,:);
                %obj.stimSequence = randsample(obj.stimSequence, length(obj.stimSequence));
            end
            obj.currentSurroundContrast = obj.stimSequence(pulseNum, 2);
            obj.currentBarWidth = obj.stimSequence(pulseNum, 1);
             if (obj.currentBarWidth > obj.apertureDiameter/2);
                obj.currentBarWidth = obj.apertureDiameter/2;
            end
            epoch.addParameter('currentSurroundContrast', obj.currentSurroundContrast);
            epoch.addParameter('currentBarWidth', obj.currentBarWidth);
        end
        
        function p = createPresentation(obj)            
            canvasSize = obj.rig.getDevice('Stage').getCanvasSize();
            p = stage.core.Presentation((obj.preTime + obj.stimTime + obj.tailTime) * 1e-3);
            p.setBackgroundColor(obj.backgroundIntensity);
            
            apertureDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.apertureDiameter);
            annulusInnerDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.annulusInnerDiameter);
            annulusOuterDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.annulusOuterDiameter);
            currentBarWidthPix = obj.rig.getDevice('Stage').um2pix(obj.currentBarWidth);
 
                % Create grating stimulus.            
               grate = stage.builtin.stimuli.Grating('square'); %square wave grating
                grate.orientation = obj.rotation;
                grate.size = [apertureDiameterPix, apertureDiameterPix];
                grate.position = canvasSize/2;
                grate.spatialFreq = 1/(2*currentBarWidthPix); %convert from bar width to spatial freq
                grate.color = 2*obj.backgroundIntensity;
                %calc to apply phase shift s.t. a contrast-reversing boundary
                %is in the center regardless of spatial frequency. Arbitrarily
                %say boundary should be positve to right and negative to left
                %crosses x axis from neg to pos every period from 0
                zeroCrossings = 0:(grate.spatialFreq^-1):grate.size(1); 
                offsets = zeroCrossings-grate.size(1)/2; %difference between each zero crossing and center of texture, pixels
                [shiftPix, ~] = min(offsets(offsets>0)); %positive shift in pixels
                phaseShift_rad = (shiftPix/(grate.spatialFreq^-1))*(2*pi); %phaseshift in radians
                phaseShift = 360*(phaseShift_rad)/(2*pi); %phaseshift in degrees
                grate.phase = phaseShift; %keep contrast reversing boundary in center
                p.addStimulus(grate);
                %hide during pre & post
                grateVisible = stage.builtin.controllers.PropertyController(grate, 'visible', ...
                    @(state)state.time >= obj.preTime * 1e-3 && state.time < (obj.preTime + obj.stimTime) * 1e-3);
                p.addController(grateVisible);
            
             %make it contrast-reversing
            if (obj.temporalFrequency > 0) 
                grateContrast = stage.builtin.controllers.PropertyController(grate, 'contrast',...
                    @(state)getGrateContrast(obj, state.time - obj.preTime/1e3));
                p.addController(grateContrast); %add the controller
            end
            function c = getGrateContrast(obj, time)
                c = obj.gratingContrast.*sin(2 * pi * obj.temporalFrequency * time);
            end
            
            if (obj.apertureDiameter > 0) %% Create aperture
                aperture = stage.builtin.stimuli.Rectangle();
                aperture.position = canvasSize/2;
                aperture.color = obj.backgroundIntensity;
                aperture.size = [max(canvasSize) max(canvasSize)];
                mask = stage.core.Mask.createCircularAperture(apertureDiameterPix/max(canvasSize), 1024); %circular aperture
                aperture.setMask(mask);
                p.addStimulus(aperture); %add aperture
            end
            
            %make annulus in surround
            rect = stage.builtin.stimuli.Rectangle();
            rect.position = canvasSize/2;
            rect.color = obj.backgroundIntensity + ...
                obj.backgroundIntensity * obj.currentSurroundContrast;
            rect.size = [max(canvasSize) max(canvasSize)];

            distanceMatrix = createDistanceMatrix(1024);
            annulus = uint8((distanceMatrix < annulusOuterDiameterPix/max(canvasSize) & ...
                distanceMatrix > annulusInnerDiameterPix/max(canvasSize)) * 255);
            mask = stage.core.Mask(annulus);

            rect.setMask(mask);
            p.addStimulus(rect);
            rectVisible = stage.builtin.controllers.PropertyController(rect, 'visible', ...
                @(state)state.time >= obj.preTime * 1e-3 && state.time < (obj.preTime + obj.stimTime) * 1e-3);
            p.addController(rectVisible);
            
            function m = createDistanceMatrix(size)
                step = 2 / (size - 1);
                [xx, yy] = meshgrid(-1:step:1, -1:step:1);
                m = sqrt(xx.^2 + yy.^2);
            end
        end
        
        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages *length(obj.stimSequence);
        end
        
        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages*length(obj.stimSequence);
        end

    end
    
end