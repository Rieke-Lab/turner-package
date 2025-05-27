classdef CheckerboardNoiseProject < edu.washington.riekelab.protocols.RiekeLabStageProtocol
    
    properties
        preTime = 500 % ms
        stimTime = 20000 % ms
        tailTime = 500 % ms
        stixelSize = 30 % um
        binaryNoise = true %binary checkers - overrides noiseStdv
        noiseStdv = 0.3 %contrast, as fraction of mean
        frameDwell = 1 % Frames per noise update
        apertureDiameter = 0 % um
        backgroundIntensity = 0.5 % (0-1)
        onlineAnalysis = 'none'
        numberOfAverages = uint16(20) % number of epochs to queue
        projectionType = 'none' % Type of projection to use
        linearFilter = '' % Path to .mat file containing the linear filter
        amp % Output amplifier
    end

    properties (Hidden)
        ampType
        onlineAnalysisType = symphonyui.core.PropertyType('char', 'row', {'none', 'extracellular', 'exc', 'inh'})
        projectionTypeType = symphonyui.core.PropertyType('char', 'row', {'none', 'linear filter'})
        noiseSeed
        noiseStream
        numChecksX
        numChecksY
        imageMatrix
        loadedFilter            % Loaded linear filter from .mat file
        useFixedSeed = true     % Toggle between fixed and random seeds
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
                obj.showFigure('edu.washington.riekelab.turner.figures.StrfFigure',...
                obj.rig.getDevice(obj.amp),obj.rig.getDevice('Frame Monitor'),...
                obj.rig.getDevice('Stage'),...
                'recordingType',obj.onlineAnalysis,...
                'preTime',obj.preTime,'stimTime',obj.stimTime,...
                'frameDwell',obj.frameDwell,'binaryNoise',obj.binaryNoise);
            end
            
            %get number of checkers...
            canvasSize = obj.rig.getDevice('Stage').getCanvasSize();
            %convert from microns to pixels...
            stixelSizePix = obj.rig.getDevice('Stage').um2pix(obj.stixelSize);
            obj.numChecksX = round(canvasSize(1) / stixelSizePix);
            obj.numChecksY = round(canvasSize(2) / stixelSizePix);

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
            
            %at start of epoch, set random stream
            obj.noiseStream = RandStream('mt19937ar', 'Seed', obj.noiseSeed);
            epoch.addParameter('noiseSeed', obj.noiseSeed);
            epoch.addParameter('numChecksX', obj.numChecksX);
            epoch.addParameter('numChecksY', obj.numChecksY);
            if ~isempty(obj.loadedFilter)
                if (obj.numEpochsCompleted == 1)
                    epoch.addParameter('linearFilter', obj.loadedFilter);
                end
            end
        end

        function p = createPresentation(obj)
            p = stage.core.Presentation((obj.preTime + obj.stimTime + obj.tailTime) * 1e-3); %create presentation of specified duration
            p.setBackgroundColor(obj.backgroundIntensity); % Set background intensity

            %convert from microns to pixels...
            apertureDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.apertureDiameter);
            
            canvasSize = obj.rig.getDevice('Stage').getCanvasSize();
            
            % Create checkerboard
            initMatrix = uint8(255.*(obj.backgroundIntensity .* ones(obj.numChecksY,obj.numChecksX)));
            board = stage.builtin.stimuli.Image(initMatrix);
            board.size = canvasSize;
            board.position = canvasSize/2;
            board.setMinFunction(GL.NEAREST); %don't interpolate to scale up board
            board.setMagFunction(GL.NEAREST);
            p.addStimulus(board);
            preFrames = round(60 * (obj.preTime/1e3));
            stmFrames = round(60 * (obj.stimTime/1e3));
            tailFrames = round(60 * (obj.tailTime/1e3));

            totFrames = preFrames + stmFrames + tailFrames;
            
            getCheckerboardFrames(obj, preFrames, stmFrames, tailFrames)
            % Pad the filter if it is shorter than the total frames
            if ~isempty(obj.loadedFilter)
                if length(obj.loadedFilter) < totFrames
                    obj.loadedFilter = [obj.loadedFilter, zeros(1, totFrames - length(obj.loadedFilter))];
                 elseif length(obj.loadedFilter) > totFrames
                    obj.loadedFilter = obj.loadedFilter(1:totFrames);
                end
                
                % Calculate projection if projectionType is specified
                if ~strcmp(obj.projectionType, 'none')
                    % Compute the projection of noise onto the linear filter
                    for x = 1:obj.numChecksX
                        for y = 1:obj.numChecksY
                            noise = squeeze(obj.imageMatrix(y, x, :))';
                            noise = real(ifft(fft(noise) .* conj(fft(obj.loadedFilter))));
                            noise = noise - mean(noise);
                            noise = noise + obj.backgroundIntensity;
                            obj.imageMatrix(y, x, :) = noise; % Replace with projection
                        end
                    end
                end
            end
            
            checkerboardController = stage.builtin.controllers.PropertyController(board, 'imageMatrix',...
                @(state)getNewCheckerboard(obj, state.frame+1));
            p.addController(checkerboardController); %add the controller
            
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
            boardVisible = stage.builtin.controllers.PropertyController(board, 'visible', ...
                @(state)state.time >= obj.preTime * 1e-3 && state.time < (obj.preTime + obj.stimTime) * 1e-3);
            p.addController(boardVisible); 

            function getCheckerboardFrames(obj, preFrames, stmFrames, tailFrames)
                obj.imageMatrix = zeros(obj.numChecksY,obj.numChecksX,preFrames+stmFrames+tailFrames);
                for frame = 1:preFrames + stmFrames
                    obj.imageMatrix(:, :, frame) = obj.backgroundIntensity;
                end
                for frame = preFrames+1:preFrames + stmFrames
                    if mod(frame-preFrames, obj.frameDwell) == 0 %noise update
                        if (obj.binaryNoise)
                            obj.imageMatrix(:, :, frame) = 2*obj.backgroundIntensity * ...
                                (obj.noiseStream.rand(obj.numChecksY,obj.numChecksX) > 0.5);
                        else
                            obj.imageMatrix(:, :, frame) = obj.backgroundIntensity + ...
                                obj.noiseStdv * obj.backgroundIntensity * ...
                                obj.noiseStream.randn(obj.numChecksY,obj.numChecksX);
                        end
                    else
                        obj.imageMatrix(:, :, frame) = obj.imageMatrix(:, :, frame-1);
                    end
                end
                for frame = preFrames + stmFrames + 1:preFrames + stmFrames + tailFrames
                    obj.imageMatrix(:, :, frame) = obj.backgroundIntensity;
                end
            end

            function i = getNewCheckerboard(obj, frame)
                i = uint8(255 * obj.imageMatrix(:, :, frame));
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