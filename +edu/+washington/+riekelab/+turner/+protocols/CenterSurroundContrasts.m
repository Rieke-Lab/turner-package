classdef CenterSurroundContrasts < edu.washington.riekelab.protocols.RiekeLabStageProtocol

    properties
        preTime = 250 % ms
        stimTime = 250 % ms
        tailTime = 500 % ms
        
        apertureDiameter = 200 % um
        annulusInnerDiameter = 300; %  um
        annulusOuterDiameter = 600; % um
        surroundContrast = [-0.95 -0.5 -0.25 0 0.25 0.5 0.75 0.95 2 3];
        spotContrast = [0.25 0.5 .95];
        backgroundIntensity = 0.33; %0-1
        randomizeOrder = false
        
        onlineAnalysis = 'none'
        amp % Output amplifier
        numberOfAverages = uint16(90) % number of epochs to queue
    end
    
    properties (Hidden)
        ampType
        onlineAnalysisType = symphonyui.core.PropertyType('char', 'row', {'none', 'extracellular', 'exc', 'inh'})
        surroundIntensityValues
        centerIntensityValues
        %surroundContrastSequence
        ContrastSequence
        %saved out to each epoch...
        stimulusTag
        currentSurroundContrast
        currentCenterContrast
    end

    methods
        
        function didSetRig(obj)
            didSetRig@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj);
            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end

        function prepareRun(obj)
            prepareRun@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj);

            obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));
            obj.showFigure('edu.washington.riekelab.turner.figures.MeanResponseFigure',...
                obj.rig.getDevice(obj.amp),'recordingType',obj.onlineAnalysis,...
                'groupBy',{'currentSurroundContrast'});
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
            % Create surround contrast sequence.
            %obj.surroundContrastSequence = obj.surroundContrast;
            
            obj.ContrastSequence = [];
            for aa = 1:length(obj.spotContrast);
                currSpot = obj.spotContrast(aa);
                holdSeq = (ones(size(obj.surroundContrast)).* currSpot)';
                obj.ContrastSequence = [obj.ContrastSequence; [obj.surroundContrast', holdSeq]];
            end
        end
        
        function prepareEpoch(obj, epoch)
            prepareEpoch@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj, epoch);
            device = obj.rig.getDevice(obj.amp);
            duration = (obj.preTime + obj.stimTime + obj.tailTime) / 1e3;
            epoch.addDirectCurrentStimulus(device, device.background, duration, obj.sampleRate);
            epoch.addResponse(device);
            pulseNum = mod(obj.numEpochsCompleted, length(obj.ContrastSequence)) + 1;

            %evenInd = mod(obj.numEpochsCompleted,2);
            evenInd = 1;
            if evenInd == 1 %even, show null
                obj.stimulusTag = 'intensity';
            elseif evenInd == 0 %odd, show grating
                obj.stimulusTag = 'image';
            end
            
            %get current surround contrast
            index = mod(obj.numEpochsCompleted, length(obj.ContrastSequence)) + 1;
            % Randomize the sequence order at the beginning of each sequence
            if pulseNum == 1 && obj.randomizeOrder
                totPermSize = size(obj.ContrastSequence);
                randInd = randperm(totPermSize(1));
                obj.ContrastSequence = obj.ContrastSequence(randInd,:);
                %obj.stimSequence = randsample(obj.stimSequence, length(obj.stimSequence));
            end
            ContrastIndex = floor(mod(obj.numEpochsCompleted, length(obj.ContrastSequence)) + 1);
            obj.currentCenterContrast = obj.ContrastSequence(ContrastIndex,2);
            obj.currentSurroundContrast = obj.ContrastSequence(ContrastIndex,1);

            epoch.addParameter('stimulusTag', obj.stimulusTag);
            epoch.addParameter('currentCenterdContrast', obj.currentCenterContrast);
            epoch.addParameter('currentSurroundContrast', obj.currentSurroundContrast);
        end
        
        function p = createPresentation(obj)            
            canvasSize = obj.rig.getDevice('Stage').getCanvasSize();
            p = stage.core.Presentation((obj.preTime + obj.stimTime + obj.tailTime) * 1e-3);
            p.setBackgroundColor(obj.backgroundIntensity);
            
            apertureDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.apertureDiameter);
            annulusInnerDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.annulusInnerDiameter);
            annulusOuterDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.annulusOuterDiameter);
            
            % Create spot stimulus.            
            spot = stage.builtin.stimuli.Ellipse();
            spot.color = (obj.currentCenterContrast * obj.backgroundIntensity + obj.backgroundIntensity);
            spot.radiusX = apertureDiameterPix/2;
            spot.radiusY = apertureDiameterPix/2;
            spot.position = canvasSize/2;
            p.addStimulus(spot);
            
            %hide during pre & post
                grateVisible = stage.builtin.controllers.PropertyController(spot, 'visible', ...
                    @(state)state.time >= obj.preTime * 1e-3 && state.time < (obj.preTime + obj.stimTime) * 1e-3);
                p.addController(grateVisible);

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
            tf = obj.numEpochsPrepared < obj.numberOfAverages;
        end
        
        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages;
        end

    end
    
end