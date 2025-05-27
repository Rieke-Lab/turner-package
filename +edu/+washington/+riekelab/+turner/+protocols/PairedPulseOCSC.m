classdef PairedPulseOCSC < edu.washington.riekelab.protocols.RiekeLabStageProtocol

    properties
        preTime = 250 % ms
        stimTime = 250 % ms
        tailTime = 500 % ms
        fixedFlashTime = 250 % ms
        flashInterval = [15 50 100]; %ms

        
        apertureDiameter = 200 % um
        annulusInnerDiameter = 400; %  um
        annulusOuterDiameter = 700; % um
        surroundContrast = [-0.95 0 1];
        spotContrast = [ 0 1 ];
        backgroundIntensity = 0.5; %0-1
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
        currentFlashInterval
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

%             holdSeq2 = [];
%             for a2 = 1:length(obj.flashInterval)
%                 currFlashInterval = obj.flashInterval(a2);
%                 holdSeq2 = [holdSeq2; obj.ContrastSequence (ones(size(obj.ContrastSequence,1),1).* currFlashInterval)];
%             end
%             obj.ContrastSequence = holdSeq2;

        end
        
        function prepareEpoch(obj, epoch)
            prepareEpoch@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj, epoch);
            device = obj.rig.getDevice(obj.amp);
            duration = (obj.preTime + obj.fixedFlashTime*2 +  + obj.tailTime) / 1e3;
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
            
            % Randomize the sequence order at the beginning of each sequence
            if pulseNum == 1 && obj.randomizeOrder
                totPermSize = size(obj.ContrastSequence);
                randInd = randperm(totPermSize(1));
                obj.ContrastSequence = obj.ContrastSequence(randInd,:);
            end
            ContrastIndex = floor(mod(obj.numEpochsCompleted, length(obj.ContrastSequence)) + 1);
            obj.currentCenterContrast = obj.ContrastSequence(ContrastIndex,2);
            obj.currentSurroundContrast = obj.ContrastSequence(ContrastIndex,1);
            obj.currentFlashInterval = obj.flashInterval(1);
            epoch.addParameter('stimulusTag', obj.stimulusTag);
            epoch.addParameter('currentCenterdContrast', obj.currentCenterContrast);
            epoch.addParameter('currentSurroundContrast', obj.currentSurroundContrast);
            epoch.addParameter('currentFlashInterval', obj.currentFlashInterval);
        end
        
        function p = createPresentation(obj)            
            canvasSize = obj.rig.getDevice('Stage').getCanvasSize();
            p = stage.core.Presentation((obj.preTime + obj.fixedFlashTime*2 + obj.currentFlashInterval + obj.tailTime) * 1e-3);
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
            
            %hide during pre & post flash, x 2 flashes, fixed flash length
                grateVisible = stage.builtin.controllers.PropertyController(spot, 'visible', ...
                    @(state)(state.time >= obj.preTime * 1e-3 && ... %flash1 on
                                state.time < (obj.preTime + obj.fixedFlashTime) * 1e-3 ) | ...%flash1 off
                    (state.time >= (obj.preTime+ obj.fixedFlashTime+obj.currentFlashInterval) * 1e-3 && ...%flash2 on
                                state.time < ( obj.preTime+ 2*obj.fixedFlashTime+obj.currentFlashInterval) * 1e-3 ));%flash2 off
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
            
            %make annulus in surround for pulse1
            rect1 = stage.builtin.stimuli.Rectangle();
            rect1.position = canvasSize/2;
            rect1.color = obj.backgroundIntensity + ...
                obj.backgroundIntensity * obj.currentSurroundContrast;
            rect1.size = [max(canvasSize) max(canvasSize)];

            distanceMatrix = createDistanceMatrix(1024);
            annulus = uint8((distanceMatrix < annulusOuterDiameterPix/max(canvasSize) & ...
                distanceMatrix > annulusInnerDiameterPix/max(canvasSize)) * 255);
            mask = stage.core.Mask(annulus);
            rect1.setMask(mask);
            p.addStimulus(rect1);

            %hide during pre & post flash, x 2 flashes, fixed flash length
            rectVisible1 = stage.builtin.controllers.PropertyController(rect1, 'visible', ...
                @(state)(state.time >= obj.preTime * 1e-3 && ... %flash1 on
                                state.time < (obj.preTime + obj.fixedFlashTime) * 1e-3 ) ); %flash1 off
            p.addController(rectVisible1);
            
             %make annulus in surround for pulse2
            rect2 = stage.builtin.stimuli.Rectangle();
            rect2.position = canvasSize/2;
            rect2.color = obj.backgroundIntensity;
            rect2.size = [max(canvasSize) max(canvasSize)];

%             distanceMatrix = createDistanceMatrix(1024);
%             annulus = uint8((distanceMatrix < annulusOuterDiameterPix/max(canvasSize) & ...
%                 distanceMatrix > annulusInnerDiameterPix/max(canvasSize)) * 255);
%             mask = stage.core.Mask(annulus);
            rect2.setMask(mask);
            p.addStimulus(rect2);

            %hide during pre & post flash, x 2 flashes, fixed flash length
            rectVisible2 = stage.builtin.controllers.PropertyController(rect2, 'visible', ...
                @(state)(state.time >= (obj.preTime+ obj.fixedFlashTime+obj.currentFlashInterval) * 1e-3 && ... %flash2 on
                                state.time < ( obj.preTime+ 2*obj.fixedFlashTime+obj.currentFlashInterval) * 1e-3 )); %flash2 off
            p.addController(rectVisible2);  
            
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