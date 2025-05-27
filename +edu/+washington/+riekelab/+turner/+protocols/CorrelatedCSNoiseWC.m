classdef CorrelatedCSNoiseWC < edu.washington.riekelab.protocols.RiekeLabStageProtocol
    
    properties
        preTime = 500 % ms
        stimTime = 4000 % ms
        tailTime = 500 % ms
        centerDiameter = 200 % um
        annulusInnerDiameter = 300 % um
        annulusOuterDiameter = 600 % um
        noiseStdv = 0.5 %contrast, as fraction of mean
        csCorrelation = [-1 0 1]; %[-1 1]
        backgroundIntensity = 0.5 % (0-1)
        frameDwell = 1 % Frames per noise update
        centerSeed = 1 % center seed = x, surround seed = x + 1
        randomizeOrder = false

        onlineAnalysis = 'extracellular'
        numberOfAverages = uint16(3) % number of epochs to queue
        amp % Output amplifier
    end

    properties (Hidden)
        ampType
        onlineAnalysisType = symphonyui.core.PropertyType('char', 'row', {'none', 'extracellular', 'exc', 'inh'})
        centerNoiseSeed
        surroundNoiseSeed
        centerNoiseStream
        surroundNoiseStream
        currentStimulus
        centerNoiseArray
        surroundNoiseArray
        currentCorrelation
        stimSequence
    end
    
    methods
        
        function didSetRig(obj)
            didSetRig@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj);
            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end
         
        function prepareRun(obj)
            prepareRun@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj);

            obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));
            obj.showFigure('edu.washington.riekelab.turner.figures.FrameTimingFigure',...
                obj.rig.getDevice('Stage'), obj.rig.getDevice('Frame Monitor'));
            if ~strcmp(obj.onlineAnalysis,'none')
                colors = edu.washington.riekelab.turner.utils.pmkmp(7,'CubicYF');
                obj.showFigure('edu.washington.riekelab.turner.figures.MeanResponseFigure',...
                obj.rig.getDevice(obj.amp),'recordingType',obj.onlineAnalysis,...
                'groupBy',{'currentStimulus'},...
                'sweepColor',colors);
            end
            
             obj.stimSequence = [0 2 0 4 0 6];
        end
        
        function prepareEpoch(obj, epoch)
            prepareEpoch@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj, epoch);
            device = obj.rig.getDevice(obj.amp);
            duration = (obj.preTime + obj.stimTime + obj.tailTime) / 1e3;
            epoch.addDirectCurrentStimulus(device, device.background, duration, obj.sampleRate);
            epoch.addResponse(device);
            
            %determine which stimulus to play this epoch
            %cycles thru center,surround, center + surround
             obj.centerNoiseSeed = obj.centerSeed;
                obj.surroundNoiseSeed = obj.centerSeed + 1;
            obj.centerNoiseStream = RandStream('mt19937ar', 'Seed', obj.centerNoiseSeed);
                obj.surroundNoiseStream = RandStream('mt19937ar', 'Seed', obj.surroundNoiseSeed);
                %pre-generate correlated noise arrays
                nFramesToPreGenerate = ceil(((obj.stimTime / 1e3) * obj.rig.getDevice('Stage').getMonitorRefreshRate()) / obj.frameDwell);
                tempC = obj.centerNoiseStream.randn(1,nFramesToPreGenerate);
                tempS = obj.surroundNoiseStream.randn(1,nFramesToPreGenerate);
                obj.centerNoiseArray = obj.backgroundIntensity + ...
                    obj.noiseStdv * obj.backgroundIntensity * tempC;
                
                %set up indeces and randomize if selected
                index = mod(obj.numEpochsCompleted, length(obj.stimSequence)) + 1;
                %index = mod(obj.numEpochsCompleted,11);
                 
                 if index == 1 && obj.randomizeOrder
                    totPermSize = size(obj.stimSequence);
                    randInd = randperm(max(totPermSize));
                    obj.stimSequence = obj.stimSequence(randInd);
                 end
                 
                 thisIndex = obj.stimSequence(index);
            if thisIndex == 0
                obj.currentStimulus = 'Center';
                obj.currentCorrelation = obj.csCorrelation(3);%fullCorrelated
                obj.surroundNoiseArray = obj.backgroundIntensity + ...
                    obj.noiseStdv * obj.backgroundIntensity *(obj.currentCorrelation*tempC+sqrt(1-obj.currentCorrelation^2)*tempS);
            elseif thisIndex == 1 % fully correlated surround
                obj.currentStimulus = 'SurroundC';
                obj.currentCorrelation = obj.csCorrelation(3);%fullCorrelated
                obj.surroundNoiseArray = obj.backgroundIntensity + ...
                    obj.noiseStdv * obj.backgroundIntensity *(obj.currentCorrelation*tempC+sqrt(1-obj.currentCorrelation^2)*tempS);
            elseif thisIndex == 2
                obj.currentStimulus = 'Center-SurroundC';
                 obj.currentCorrelation = obj.csCorrelation(3);%fullCorrelated
                obj.surroundNoiseArray = obj.backgroundIntensity + ...
                    obj.noiseStdv * obj.backgroundIntensity *(obj.currentCorrelation*tempC+sqrt(1-obj.currentCorrelation^2)*tempS);
            elseif thisIndex == 3 % independent surround
                obj.currentStimulus = 'SurroundI';
                obj.currentCorrelation = obj.csCorrelation(2);%fullCorrelated
                obj.surroundNoiseArray = obj.backgroundIntensity + ...
                    obj.noiseStdv * obj.backgroundIntensity *(obj.currentCorrelation*tempC+sqrt(1-obj.currentCorrelation^2)*tempS);
            elseif thisIndex == 4
                obj.currentStimulus = 'Center-SurroundI';
                 obj.currentCorrelation = obj.csCorrelation(2);%fullCorrelated
                obj.surroundNoiseArray = obj.backgroundIntensity + ...
                    obj.noiseStdv * obj.backgroundIntensity *(obj.currentCorrelation*tempC+sqrt(1-obj.currentCorrelation^2)*tempS);
            elseif thisIndex == 5 % anticorrelated surround
                obj.currentStimulus = 'SurroundA';
                obj.currentCorrelation = obj.csCorrelation(1);%antiCorrelated
                obj.surroundNoiseArray = obj.backgroundIntensity + ...
                    obj.noiseStdv * obj.backgroundIntensity *(obj.currentCorrelation*tempC+sqrt(1-obj.currentCorrelation^2)*tempS);
            elseif thisIndex == 6
                obj.currentStimulus = 'Center-SurroundA';
                 obj.currentCorrelation = obj.csCorrelation(1);%fullCorrelated
                obj.surroundNoiseArray = obj.backgroundIntensity + ...
                    obj.noiseStdv * obj.backgroundIntensity *(obj.currentCorrelation*tempC+sqrt(1-obj.currentCorrelation^2)*tempS);
            end

            epoch.addParameter('centerNoiseSeed', obj.centerNoiseSeed);
            epoch.addParameter('surroundNoiseSeed', obj.surroundNoiseSeed);
            epoch.addParameter('currentStimulus', obj.currentStimulus);
            epoch.addParameter('centerNoiseArray', obj.centerNoiseArray);
            epoch.addParameter('surroundNoiseArray', obj.surroundNoiseArray);
            epoch.addParameter('currentCorrelation', obj.currentCorrelation);
        end

        function p = createPresentation(obj)
            canvasSize = obj.rig.getDevice('Stage').getCanvasSize();
            
            %convert from microns to pixels...
            centerDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.centerDiameter);
            annulusInnerDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.annulusInnerDiameter);
            annulusOuterDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.annulusOuterDiameter);
            
            p = stage.core.Presentation((obj.preTime + obj.stimTime + obj.tailTime) * 1e-3); %create presentation of specified duration
            p.setBackgroundColor(obj.backgroundIntensity); % Set background intensity
            preFrames = round(60 * (obj.preTime/1e3));
            if or(strncmp(obj.currentStimulus, 'Surround',8), strncmp(obj.currentStimulus, 'Center-Surround',15))       
                surroundSpot = stage.builtin.stimuli.Ellipse();
                surroundSpot.radiusX = annulusOuterDiameterPix/2;
                surroundSpot.radiusY = annulusOuterDiameterPix/2;
                surroundSpot.position = canvasSize/2;
                p.addStimulus(surroundSpot);
                surroundSpotIntensity = stage.builtin.controllers.PropertyController(surroundSpot, 'color',...
                    @(state)getSurroundIntensity(obj, state.frame - preFrames));
                p.addController(surroundSpotIntensity);
                % hide during pre & post
                surroundSpotVisible = stage.builtin.controllers.PropertyController(surroundSpot, 'visible', ...
                    @(state)state.time >= obj.preTime * 1e-3 && state.time < (obj.preTime + obj.stimTime) * 1e-3);
                p.addController(surroundSpotVisible);
                %mask / annulus...
                maskSpot = stage.builtin.stimuli.Ellipse();
                maskSpot.radiusX = annulusInnerDiameterPix/2;
                maskSpot.radiusY = annulusInnerDiameterPix/2;
                maskSpot.position = canvasSize/2;
                maskSpot.color = obj.backgroundIntensity;
                p.addStimulus(maskSpot);
            end
            if or(strcmp(obj.currentStimulus, 'Center'), strncmp(obj.currentStimulus, 'Center-Surround',15))
                centerSpot = stage.builtin.stimuli.Ellipse();
                centerSpot.radiusX = centerDiameterPix/2;
                centerSpot.radiusY = centerDiameterPix/2;
                centerSpot.position = canvasSize/2;
                p.addStimulus(centerSpot);
                centerSpotIntensity = stage.builtin.controllers.PropertyController(centerSpot, 'color',...
                    @(state)getCenterIntensity(obj, state.frame - preFrames));
                p.addController(centerSpotIntensity);
                % hide during pre & post
                centerSpotVisible = stage.builtin.controllers.PropertyController(centerSpot, 'visible', ...
                    @(state)state.time >= obj.preTime * 1e-3 && state.time < (obj.preTime + obj.stimTime) * 1e-3);
                p.addController(centerSpotVisible);
            end

            function i = getCenterIntensity(obj, frame)
                persistent intensity;
                if frame<0 %pre frames. frame 0 starts stimPts
                    intensity = obj.backgroundIntensity;
                else %in stim frames
                    if mod(frame, obj.frameDwell) == 0 %noise update
                        ind = min(frame/obj.frameDwell + 1, length(obj.centerNoiseArray));
                        intensity = obj.centerNoiseArray(ind);
                    end
                end
                i = intensity;
            end
            
            function i = getSurroundIntensity(obj, frame)
                persistent intensity;
                if frame<0 %pre frames. frame 0 starts stimPts
                    intensity = obj.backgroundIntensity;
                else %in stim frames
                    if mod(frame, obj.frameDwell) == 0 %noise update
                        ind = min(frame/obj.frameDwell + 1, length(obj.surroundNoiseArray));
                        intensity = obj.surroundNoiseArray(ind);
                    end
                end
                i = intensity;
            end

        end
        function tf = shouldContinuePreparingEpochs(obj)
            %tf = obj.numEpochsPrepared < obj.numberOfAverages;
             tf = obj.numEpochsPrepared < obj.numberOfAverages * length(obj.stimSequence);
        end
        
        function tf = shouldContinueRun(obj)
            %tf = obj.numEpochsCompleted < obj.numberOfAverages;
             tf = obj.numEpochsCompleted < obj.numberOfAverages * length(obj.stimSequence);
        end
    end
    
end