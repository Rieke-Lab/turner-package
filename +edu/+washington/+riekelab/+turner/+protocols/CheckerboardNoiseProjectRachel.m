classdef CheckerboardNoiseProjectRachel < edu.washington.riekelab.protocols.RiekeLabStageProtocol
    
    properties
        preTime = 500 % ms
        stimTime = 20000 % ms
        tailTime = 500 % ms
        stixelSize = 30 % um
        binaryNoise = true %binary checkers - overrides noiseStdv
        pairedBars = true
        noiseStdv = 0.3 %contrast, as fraction of mean
        frameDwell = 1 % Frames per noise update
        backgroundFrameDwells = [10 20 30 60] % Frames per noise update
        backgroundRatio = 0.2
        apertureDiameter = 0 % um
        backgroundIntensity = 0.5 % (0-1)
        onlineAnalysis = 'none'
        numberOfAverages = uint16(20) % number of epochs to queue
        amp % Output amplifier
        xOffset = -58 %offset of image to move split field, in pixels, default is equal sides with frame monitor for vert bars
        yOffset = 0 %offset of image to move split field, in pixels
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
        lineMatrix
        dimBackground
        loadedFilter            % Loaded linear filter from .mat file
        useFixedSeed = true     % Toggle between fixed and random seeds
        backgroundFrameDwell
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
            obj.dimBackground = 0;

         end
        
        function prepareEpoch(obj, epoch)
            fprintf(1, 'start prepare epoc\n');
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
            
            %Choose next background frame dwell 
            obj.backgroundFrameDwell = obj.backgroundFrameDwells(mod(obj.numEpochsCompleted,length(obj.backgroundFrameDwells))+1);
            
            %at start of epoch, set random stream
            obj.noiseStream = RandStream('mt19937ar', 'Seed', obj.noiseSeed);
            epoch.addParameter('noiseSeed', obj.noiseSeed);
            epoch.addParameter('numChecksX', obj.numChecksX);
            epoch.addParameter('numChecksY', obj.numChecksY);
            fprintf(1, 'end prepare epoc\n');
         end

         function p = createPresentation(obj)
            fprintf(1, 'start create presentation\n');
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
            board.position = board.position + [obj.xOffset obj.yOffset];
            board.setMinFunction(GL.NEAREST); %don't interpolate to scale up board
            board.setMagFunction(GL.NEAREST);
            p.addStimulus(board);
            preFrames = round(60 * (obj.preTime/1e3));
            stmFrames = round(60 * (obj.stimTime/1e3));
            tailFrames = round(60 * (obj.tailTime/1e3));

            totFrames = preFrames + stmFrames + tailFrames;
            
            getCheckerboardLines(obj, preFrames, stmFrames, tailFrames)
            
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
            
            function getCheckerboardLines(obj, preFrames, stmFrames, tailFrames)
                obj.lineMatrix = zeros(obj.numChecksX,preFrames+stmFrames+tailFrames);
                for frame = 1:preFrames + stmFrames
                    obj.lineMatrix(:, frame) = obj.backgroundIntensity;
                end
                Indices = [1:floor(obj.numChecksX/2)]*2;
                for frame = preFrames+1:preFrames+stmFrames
                    if mod(frame-preFrames, obj.frameDwell) == 0 %noise update
                        if (obj.binaryNoise)
                            obj.lineMatrix(:, frame) = 2 *obj.backgroundIntensity * ...
                                (obj.noiseStream.rand(obj.numChecksX, 1) > 0.5);
                        else
                            obj.lineMatrix(:, frame) = obj.backgroundIntensity + ...
                                obj.noiseStdv * obj.backgroundIntensity * ...
                                obj.noiseStream.randn(obj.numChecksX, 1);
                        end
                    else
                        obj.lineMatrix(:, frame) = obj.lineMatrix(:, frame-1);
                    end
                    if (obj.pairedBars)
                        obj.lineMatrix(Indices, frame) = -(obj.lineMatrix(Indices-1, frame)-obj.backgroundIntensity)+ ...
                            obj.backgroundIntensity;
                    end
%                     if (mod(frame-preFrames, obj.backgroundFrameDwell) == 0)
%                         Indices = [1:floor(obj.numChecksX/2)];
%                         obj.lineMatrix(Indices, frame) = obj.lineMatrix(Indices, frame) * obj.backgroundRatio;
%                         if (obj.dimBackground == 0)
%                             obj.dimBackground = 1;
%                         else
%                             obj.dimBackground = 0;
%                         end
%                     end
                    if mod(frame-preFrames, obj.backgroundFrameDwell) == 0
                        if (obj.dimBackground == 0)
                            obj.dimBackground = 1;
                        else
                            obj.dimBackground = 0;
                        end
                    end
                    Indices1 = [1:floor(obj.numChecksX/2)];
                    Indices2 = [floor(obj.numChecksX/2):obj.numChecksX];
                    if obj.dimBackground == 0
                        obj.lineMatrix(Indices1, frame) = obj.lineMatrix(Indices1, frame) - obj.backgroundRatio;
                        obj.lineMatrix(Indices2, frame) = obj.lineMatrix(Indices2, frame) + obj.backgroundRatio;
                    else
                        obj.lineMatrix(Indices1, frame) = obj.lineMatrix(Indices1, frame) + obj.backgroundRatio;
                        obj.lineMatrix(Indices2, frame) = obj.lineMatrix(Indices2, frame) - obj.backgroundRatio;
                    end
                end
                for frame = preFrames + stmFrames + 1:preFrames + stmFrames + tailFrames
                    obj.lineMatrix(:, frame) = obj.backgroundIntensity;
                end
            end

            function i = getNewCheckerboard(obj, frame)
                line = obj.lineMatrix(:, frame);
                i = uint8(255 * repmat(line', obj.numChecksY, 1));
                size(i)
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