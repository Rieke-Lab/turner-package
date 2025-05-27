classdef FullFieldNoiseProject < edu.washington.riekelab.protocols.RiekeLabStageProtocol
    
    properties
        preTime = 500 % ms
        stimTime = 8000 % ms
        tailTime = 500 % ms
        apertureDiameter = 0 % um
        noiseStdv = 0.3 % contrast, as fraction of mean
        backgroundIntensity = 0.5 % (0-1)
        frameDwell = 1 % Frames per noise update
        frameRate = 60
        onlineAnalysis = 'none'
        numberOfAverages = uint16(10) % number of epochs to queue
        projectionType = 'none' % Type of projection to use
        linearFilter = '' % Path to .mat file containing the linear filter
        amp % Output amplifier
   end
    
    properties (Hidden)
        ampType
        onlineAnalysisType = symphonyui.core.PropertyType('char', 'row', {'none', 'extracellular', 'exc', 'inh'})
        projectionTypeType = symphonyui.core.PropertyType('char', 'row', {'none', 'linear filter'})
        
        noiseSeed               % Seed for random number generator
        noiseStream             % Random stream for noise generation
        noiseValues             % Precomputed noise values for the current epoch
        loadedFilter            % Loaded linear filter from .mat file
        useFixedSeed = true     % Toggle between fixed and random seeds
    end
    
    methods
        
        function didSetRig(obj)
            didSetRig@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj);
            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end
        
        function prepareRun(obj)
            % Prepare to run the protocol, including any one-time setup
            prepareRun@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj);

            obj.showFigure('symphonyui.builtin.figures.ResponseFigure', obj.rig.getDevice(obj.amp));
            obj.showFigure('edu.washington.riekelab.turner.figures.FrameTimingFigure',...
            obj.rig.getDevice('Stage'), obj.rig.getDevice('Frame Monitor'));

            if ~strcmp(obj.onlineAnalysis,'none')
                obj.showFigure('edu.washington.riekelab.turner.figures.LinearFilterFigurePreComputeNoise',...
                obj.rig.getDevice(obj.amp),obj.rig.getDevice('Frame Monitor'),...
                obj.rig.getDevice('Stage'),...
                'recordingType',obj.onlineAnalysis,'preTime',obj.preTime,  ...
                'stimTime',obj.stimTime,'frameDwell',obj.frameDwell,'frameRate',obj.frameRate, ...
                'noiseStdv',obj.noiseStdv);
            end
            
            % Get the frame rate. Need to check if it's a LCR rig.
            if ~isempty(strfind(obj.rig.getDevice('Stage').name, 'LightCrafter'))
                obj.frameRate = obj.rig.getDevice('Stage').getPatternRate();
            else
                obj.frameRate = obj.rig.getDevice('Stage').getMonitorRefreshRate();
            end
            
            % Load linear filter if the path is specified
            if ~isempty(obj.linearFilter)
                load(obj.linearFilter);
                if ~exist('linearFilter')
                    error('The specified .mat file does not contain a variable named ''filter''.');
                else
                    if (-min(linearFilter) > max(linearFilter))
                        linearFilter = -linearFilter;
                    end
                    obj.loadedFilter = linearFilter / sqrt(sum(linearFilter .* linearFilter)) / sqrt(2);
                end
                figure(); plot(obj.loadedFilter); pause(1);
            end
            
        end

        function p = createPresentation(obj)
            canvasSize = obj.rig.getDevice('Stage').getCanvasSize();
            
            %convert from microns to pixels...
            apertureDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.apertureDiameter);
            
            p = stage.core.Presentation((obj.preTime + obj.stimTime + obj.tailTime) * 1e-3); %create presentation of specified duration
            p.setBackgroundColor(obj.backgroundIntensity); % Set background intensity
            
            % Create noise stimulus.            
            noiseRect = stage.builtin.stimuli.Rectangle();
            noiseRect.size = canvasSize;
            noiseRect.position = canvasSize/2;
            p.addStimulus(noiseRect);

            % Noise controller for full-field background
            noiseValue = stage.builtin.controllers.PropertyController(noiseRect, 'color',...
                @(state)getNoiseIntensity(obj, state.time - obj.preTime/1e3));
            p.addController(noiseValue); %add the controller
            
            if (obj.apertureDiameter > 0) %% Create aperture
                aperture = stage.builtin.stimuli.Rectangle();
                aperture.position = canvasSize/2;
                aperture.color = obj.backgroundIntensity;
                aperture.size = [max(canvasSize) max(canvasSize)];
                mask = stage.core.Mask.createCircularAperture(apertureDiameterPix/max(canvasSize), 1024); %circular aperture
                aperture.setMask(mask);
                p.addStimulus(aperture); %add aperture
            end
            
            % hide during pre & post
            noiseRectVisible = stage.builtin.controllers.PropertyController(noiseRect, 'visible', ...
                @(state)state.time >= obj.preTime * 1e-3 && state.time < (obj.preTime + obj.stimTime) * 1e-3);
            p.addController(noiseRectVisible);
        end

        function intensity = getNoiseIntensity(obj, curTime)
            frame = floor(curTime * obj.frameRate);
            % Access precomputed noise values for the given frame
            if (frame <= 0)
                intensity = obj.backgroundIntensity; % Default to background after stimTime
            end
            if (frame > length(obj.noiseValues * obj.frameDwell))
                intensity = obj.backgroundIntensity; % Default to background after stimTime
            end
            if (frame > 0 & frame <= (length(obj.noiseValues) * obj.frameDwell))
                displayFrame = ceil(frame/obj.frameDwell);
                intensity = obj.noiseValues(displayFrame);
            end
        end
                
       function prepareEpoch(obj, epoch)
            prepareEpoch@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj, epoch);
            device = obj.rig.getDevice(obj.amp);
            duration = (obj.preTime + obj.stimTime + obj.tailTime) / 1e3;
            epoch.addDirectCurrentStimulus(device, device.background, duration, obj.sampleRate);
            epoch.addResponse(device);
                         
            % Alternating seed for each epoch
            if obj.useFixedSeed
                obj.noiseSeed = 1;
            else
                obj.noiseSeed = randi(2^32 - 1);
            end
            obj.noiseStream = RandStream('mt19937ar', 'Seed', obj.noiseSeed);
            
            % Toggle the seed usage for the next epoch
            obj.useFixedSeed = ~obj.useFixedSeed;
            
            % Calculate total number of noise frames based on stimTime and frameDwell
            totalFrames = ceil(obj.frameRate * obj.stimTime / 1000 / obj.frameDwell);
            
            % Precompute all noise values and store them in noiseValues
            obj.noiseValues = obj.noiseStream.randn(1, totalFrames) * obj.noiseStdv + obj.backgroundIntensity;
            
            % Pad the filter if it is shorter than the total frames
            if ~isempty(obj.loadedFilter)
                if length(obj.loadedFilter) < totalFrames
                    obj.loadedFilter = [obj.loadedFilter, zeros(1, totalFrames - length(obj.loadedFilter))];
                elseif length(obj.loadedFilter) > totalFrames
                    obj.loadedFilter = obj.loadedFilter(1:totalFrames);
                end
                
                % Calculate projection if projectionType is specified
                if ~strcmp(obj.projectionType, 'none')
                    % Compute the projection of noise onto the linear filter
                    noiseProjection = real(ifft(fft(obj.noiseValues) .* conj(fft(obj.loadedFilter))));
                    noiseProjection = noiseProjection - mean(noiseProjection);
                    noiseProjection = noiseProjection + obj.backgroundIntensity;
                    obj.noiseValues = noiseProjection; % Replace with projection
                    if (obj.numEpochsCompleted == 1)
                        epoch.addParameter('linearFilter', obj.loadedFilter);
                    end
                end
            end
            
            % Ensure values are clipped between 0 and 1
            obj.noiseValues = max(0, min(1, obj.noiseValues));

            epoch.addParameter('noiseSeed', obj.noiseSeed);
        end

        
        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages;
        end
        
        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted < obj.numberOfAverages;
        end
       
    end
end
