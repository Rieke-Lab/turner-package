classdef EyeMovementTrajectoryAlternatingBackground < edu.washington.riekelab.protocols.RiekeLabStageProtocol
    
    properties
        preTime = 200 % ms
        stimTime = 4000 % ms
        tailTime = 200 % ms
        patchMean = 'all'
        apertureDiameter = 0 % um
        randomSeed = 1 % for eye movement trajectory
        D = 5; % Drift diffusion coefficient, in microns
        backgroundScale = [0.1 10]; % scale factor for background relative to image mean
        onlineAnalysis = 'none'
        numberOfAverages = uint16(5) % number of epochs to queue
        amp % Output amplifier
    end
    
    properties (Hidden)
        ampType
        imageNames={'00152','01769','03760'};
        patchMeanType = symphonyui.core.PropertyType('char', 'row', {'all','negative','positive'})
        onlineAnalysisType = symphonyui.core.PropertyType('char', 'row', {'none', 'extracellular', 'exc', 'inh'})
        backgroundIntensity
        currentBackgroundScale
        currentImageMean
        imageMeans
        imageMatrixes
        currentImageMatrix
        currentStimSet
        currentImageSet
        currentP0
        xTraj
        yTraj
        timeTraj
        p0
        xTraj_save
        yTraj_save
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
                obj.rig.getDevice(obj.amp),'recordingType',obj.onlineAnalysis);
            obj.showFigure('edu.washington.riekelab.turner.figures.FrameTimingFigure',...
                obj.rig.getDevice('Stage'), obj.rig.getDevice('Frame Monitor'));
            
            % get current image and stim (library) set:
            resourcesDir = 'C:\Users\chenq\Documents\turner-package\resources\';
            obj.currentImageSet = 'VHsubsample_20160105';
            obj.currentStimSet = 'SaccadeLocationsLibrary_20171011';
            load([resourcesDir,obj.currentStimSet,'.mat']);
            for i=1:numel(obj.imageNames)
                fieldName = ['imk', obj.imageNames{i}];
                
                %load appropriate image...
                obj.currentStimSet = '\VHsubsample_20160105';
                fileId=fopen([resourcesDir, obj.currentImageSet, '\imk', obj.imageNames{i},'.iml'],'rb','ieee-be');
                img = fread(fileId, [1536,1024], 'uint16');
                img = double(img);
                img = (img./max(img(:))); %rescale s.t. brightest point is maximum monitor level
                img = img.*255; %rescale s.t. brightest point is maximum monitor level
                obj.imageMatrixes{i} = uint8(img');
                
                %1) restrict to desired patch mean luminance:
                obj.imageMeans(i) = imageData.(fieldName).imageMean;

                locationMean = imageData.(fieldName).patchMean;
                
                if strcmp(obj.patchMean,'all')
                    inds = 1:length(locationMean);
                elseif strcmp(obj.patchMean,'positive')
                    inds = find((locationMean-obj.imageMeans(i)) > 0);
                elseif strcmp(obj.patchMean,'negative')
                    inds = find((locationMean-obj.imageMeans(i)) <= 0);
                end
                rng(obj.randomSeed); %set random seed for fixation draw
                drawInd = randsample(inds,1);
                obj.p0(i,1) = imageData.(fieldName).location(drawInd,1);
                obj.p0(i,2) = imageData.(fieldName).location(drawInd,2);
                
                %size of the stimulus on the prep:
                %scalingFactor: 3.3 for 1 arcmin/VH pixel (like DOVES), based
                %on 198 um/degree on monkey retina
                
                % make eye movement trajectory.
                rng(obj.randomSeed); %set random seed for fixation draw
                noFrames = obj.rig.getDevice('Stage').getMonitorRefreshRate() * (obj.stimTime/1e3);
                noFrames_perLoop = noFrames/2;
                
                %generate random walk out
                tempX_1 = obj.D .* randn(1,round(noFrames_perLoop/2));
                tempY_1 = obj.D .* randn(1,round(noFrames_perLoop/2));
                %hold off first step to subtract later
                tempX_1_a = tempX_1(2:end);
                tempY_1_b = tempY_1(2:end);
                %randomize walk back
                tempX_2 = [-tempX_1_a(randperm(length(tempX_1_a))), -tempX_1(1)];
                tempY_2 = [-tempY_1_b(randperm(length(tempY_1_b))), -tempY_1(1)];
                
                %cumulative sum, flip to start at 0
                obj.xTraj = fliplr(cumsum([tempX_1, tempX_2]));
                obj.yTraj = fliplr(cumsum([tempY_1, tempY_2]));
                
                obj.xTraj = [obj.xTraj, obj.xTraj]; %do the loop twice
                obj.yTraj = [obj.yTraj, obj.yTraj]; %do the loop twice
                
                obj.xTraj_save = obj.xTraj; %still in VH coordinates
                obj.yTraj_save = obj.yTraj;
                
                obj.timeTraj = (0:(length(obj.xTraj)-1)) ./...
                    obj.rig.getDevice('Stage').getMonitorRefreshRate(); %sec
                
                %need to make eye trajectories for PRESENTATION relative to the center of the image and
                %flip them across the x axis: to shift scene right, move
                %position left, same for y axis
                obj.xTraj = -(obj.xTraj); %units=VH pixels
                obj.yTraj = -(obj.yTraj);
                %also scale them to canvas pixels
                %canvasPix = (um) / (um/canvasPix)
                obj.xTraj = obj.xTraj ./obj.rig.getDevice('Stage').getConfigurationSetting('micronsPerPixel');
                obj.yTraj = obj.yTraj ./obj.rig.getDevice('Stage').getConfigurationSetting('micronsPerPixel');
                
            end
        end
        
        function p = createPresentation(obj)
            canvasSize = obj.rig.getDevice('Stage').getCanvasSize();
            
            apertureDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.apertureDiameter);
            
            p = stage.core.Presentation((obj.preTime + obj.stimTime + obj.tailTime) * 1e-3);
            p.setBackgroundColor(obj.backgroundIntensity);
            
            scene = stage.builtin.stimuli.Image(obj.currentImageMatrix);
            %scale up image for canvas. Now image pixels and canvas pixels
            %are the same size. Also image size is in rows (y), cols (x)
            %but stage sizes are in x, y
            %canvasPix = (VHpix) * (um/VHpix)/(um/canvasPix)
            scene.size = [size(obj.currentImageMatrix,2) * (3.3)/obj.rig.getDevice('Stage').getConfigurationSetting('micronsPerPixel'),...
                size(obj.currentImageMatrix,1) * (3.3)/obj.rig.getDevice('Stage').getConfigurationSetting('micronsPerPixel')];
            
            tempY = obj.currentP0(2); %swap row/column for y/x
            tempX = obj.currentP0(1);
            %translate about center, shift to (0,0)
            translatedX = -(tempX - 1536/2);
            translatedY = (tempY - 1024/2);
            translatedLocation = [translatedX, translatedY];
            %scale to canvas pixels
            translatedLocation = translatedLocation .* (3.3)/obj.rig.getDevice('Stage').getConfigurationSetting('micronsPerPixel');
            %re-center on canvas center
            translatedLocation = canvasSize/2 + translatedLocation;
            scene.position = translatedLocation;
            
            % Use linear interpolation when scaling the image.
            scene.setMinFunction(GL.LINEAR);
            scene.setMagFunction(GL.LINEAR);
            
            %apply eye trajectories to move image around
            scenePosition = stage.builtin.controllers.PropertyController(scene,...
                'position', @(state)getScenePosition(obj, state.time - obj.preTime/1e3, translatedLocation));
            
            function p = getScenePosition(obj, time, p0)
                if time < 0
                    p = p0;
                elseif time > obj.timeTraj(end) %out of eye trajectory, hang on last frame
                    p(1) = p0(1) + obj.xTraj(end);
                    p(2) = p0(2) + obj.yTraj(end);
                else %within eye trajectory and stim time
                    dx = interp1(obj.timeTraj,obj.xTraj,time);
                    dy = interp1(obj.timeTraj,obj.yTraj,time);
                    p(1) = p0(1) + dx;
                    p(2) = p0(2) + dy;
                end
            end
            
            p.addStimulus(scene);
            p.addController(scenePosition);
            
            sceneVisible = stage.builtin.controllers.PropertyController(scene, 'visible', ...
                @(state)state.time >= obj.preTime * 1e-3 && state.time < (obj.preTime + obj.stimTime) * 1e-3);
            p.addController(sceneVisible);
            
            if (obj.apertureDiameter > 0) %% Create aperture
                aperture = stage.builtin.stimuli.Rectangle();
                aperture.position = canvasSize/2;
                %                 aperture.color = obj.backgroundIntensity;
                aperture.color = obj.currentImageMean;
                
                aperture.size = 2.*[max(canvasSize) max(canvasSize)];
                mask = stage.core.Mask.createCircularAperture(apertureDiameterPix/(2*max(canvasSize)), 1024); %circular aperture
                aperture.setMask(mask);
                p.addStimulus(aperture); %add aperture
            end
        end
        
        function prepareEpoch(obj, epoch)
            prepareEpoch@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj, epoch);
            
            device = obj.rig.getDevice(obj.amp);
            duration = (obj.preTime + obj.stimTime + obj.tailTime) / 1e3;
            epoch.addDirectCurrentStimulus(device, device.background, duration, obj.sampleRate);
            epoch.addResponse(device);
            
            % alternating the background and the movie sets 
            bgIndex= mod(obj.numEpochsCompleted,length(obj.backgroundScale))+1;
            imageIndex=  (obj.numEpochsCompleted-mod(obj.numEpochsCompleted,numel(obj.backgroundScale)))/numel(obj.backgroundScale);
            imageIndex=mod(imageIndex,length(obj.imageNames))+1;
            obj.currentBackgroundScale=obj.backgroundScale(bgIndex);
            obj.currentImageMean=obj.imageMeans(imageIndex); 
            obj.backgroundIntensity=obj.imageMeans(imageIndex)*obj.currentBackgroundScale;
            obj.currentImageMatrix=obj.imageMatrixes{imageIndex}; 
            obj.currentP0= obj.p0(imageIndex,:); 
            epoch.addParameter('backgroundIntensity', obj.backgroundIntensity);
            epoch.addParameter('currentBackgroundScale', obj.currentBackgroundScale);
            epoch.addParameter('currentImageMean', obj.currentImageMean);
            epoch.addParameter('currentImageName', obj.imageNames{imageIndex});
            epoch.addParameter('currentP0', obj.currentP0);
            epoch.addParameter('randomSeed', obj.randomSeed);
            epoch.addParameter('currentStimSet',obj.currentStimSet);
            epoch.addParameter('currentImageSet',obj.currentImageSet);
            epoch.addParameter('xTraj',obj.xTraj_save);
            epoch.addParameter('yTraj',obj.yTraj_save);
        end
        
        % %         %same presentation each epoch in a run. Replay.
        % %         function controllerDidStartHardware(obj)
        % %             controllerDidStartHardware@edu.washington.riekelab.protocols.RiekeLabProtocol(obj);
        % %             if (obj.numEpochsCompleted >= 1) && (obj.numEpochsCompleted < obj.numberOfAverages)
        % %                 obj.rig.getDevice('Stage').replay
        % %             else
        % %                 obj.rig.getDevice('Stage').play(obj.createPresentation());
        % %             end
        % %         end
        
        function tf = shouldContinuePreparingEpochs(obj)
            tf = obj.numEpochsPrepared < obj.numberOfAverages*numel(obj.backgroundScale)*numel(obj.imageNames);
        end
        
        function tf = shouldContinueRun(obj)
            tf = obj.numEpochsCompleted <  obj.numberOfAverages*numel(obj.backgroundScale)*numel(obj.imageNames);
        end
        
    end
    
end