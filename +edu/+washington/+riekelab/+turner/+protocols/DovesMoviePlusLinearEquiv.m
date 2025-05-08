classdef DovesMoviePlusLinearEquiv < manookinlab.protocols.ManookinLabStageProtocol
    properties
        amp                             % Output amplifier
        preTime = 250                   % Stimulus leading duration (ms)
        stimTime = 6000                 % Stimulus duration (ms)
        tailTime = 500                  % Stimulus trailing duration (ms)
        waitTime = 1000                 % Stimulus wait duration (ms)
        stimulusIndices = [2 6 12 18 24 30 40 50]         % Stimulus number (1:161)
        maskDiameter = 0                % Mask diameter in pixels
        apertureDiameter = 2000         % Aperture diameter in pixels.
        centerSigma = 50;               % standard deviation of RF center in microns 
        manualMagnification = 0         % Override DOVES magnification by setting this >1
        freezeFEMs = false
        onlineAnalysis = 'extracellular'% Type of online analysis
        numberOfAverages = uint16(48)   % Number of epochs
    end
    
    properties (Hidden)
        ampType
        onlineAnalysisType = symphonyui.core.PropertyType('char', 'row', {'none', 'extracellular', 'spikes_CClamp', 'subthresh_CClamp', 'analog'})
        imageMatrix
        backgroundIntensity
        xTraj
        yTraj
        timeTraj
        imageName
        subjectName
        magnificationFactor
        currentStimSet
        stimulusIndex
        pkgDir
        im
        centerContrasts
        weightingFxn
        centerSigmaPix
    end
    
    methods
        
        function didSetRig(obj)
            didSetRig@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj);
            
            [obj.amp, obj.ampType] = obj.createDeviceNamesProperty('Amp');
        end
        
        function prepareRun(obj)
            prepareRun@manookinlab.protocols.ManookinLabStageProtocol(obj);
            
            if ~obj.isMeaRig
                obj.showFigure('manookinlab.figures.ResponseFigure', obj.rig.getDevices('Amp'), ...
                    'numberOfAverages', obj.numberOfAverages);

                obj.showFigure('manookinlab.figures.MeanResponseFigure', ...
                    obj.rig.getDevice(obj.amp),'recordingType',obj.onlineAnalysis,...
                    'sweepColor',[0 0 0]);
            end
            
            % Get the resources directory.
            obj.pkgDir = manookinlab.Package.getResourcePath();
            fprintf(1, '%s\n', obj.pkgDir);
            
            obj.currentStimSet = 'dovesFEMstims20160826.mat';
            
            % Load the current stimulus set.
            obj.im = load([obj.pkgDir,'\',obj.currentStimSet]);
            
            % Get the image and subject names.
            if length(unique(obj.stimulusIndices)) == 1
                obj.stimulusIndex = unique(obj.stimulusIndices);
                obj.getImageSubject();
            end
        end
        
        function getImageSubject(obj)
            % Get the image name.
            obj.imageName = obj.im.FEMdata(obj.stimulusIndex).ImageName;
            
            % Load the image.
            fileId = fopen([obj.pkgDir,'\doves\images\', obj.imageName],'rb','ieee-be');
            img = fread(fileId, [1536 1024], 'uint16');
            fclose(fileId);
            
            img = double(img');
            img = (img./max(img(:))); %rescale s.t. brightest point is maximum monitor level
            obj.backgroundIntensity = mean(img(:));%set the mean to the mean over the image
            img = img.*255; %rescale s.t. brightest point is maximum monitor level
            obj.imageMatrix = uint8(img);
            
            %get appropriate eye trajectories, at 200Hz
            if (obj.freezeFEMs) %freeze FEMs, hang on fixations
                obj.xTraj = obj.im.FEMdata(obj.stimulusIndex).frozenX;
                obj.yTraj = obj.im.FEMdata(obj.stimulusIndex).frozenY;
            else %full FEM trajectories during fixations
                obj.xTraj = obj.im.FEMdata(obj.stimulusIndex).eyeX;
                obj.yTraj = obj.im.FEMdata(obj.stimulusIndex).eyeY;
            end
            obj.timeTraj = (0:(length(obj.xTraj)-1)) ./ 200; %sec
            
            %need to make eye trajectories for PRESENTATION relative to the center of the image and
            %flip them across the x axis: to shift scene right, move
            %position left, same for y axis - but y axis definition is
            %flipped for DOVES data (uses MATLAB image convention) and
            %stage (uses positive Y UP/negative Y DOWN), so flips cancel in
            %Y direction
            xTraj = -(obj.xTraj - 1536/2); %units=VHpixels
            yTraj = (obj.yTraj - 1024/2);
            
            %also scale them to canvas pixels. 1 VH pixel = 1 arcmin = 3.3
            %um on monkey retina
            %canvasPix = (VHpix) * (um/VHpix)/(um/canvasPix)
            obj.xTraj = xTraj .* 3.3/obj.rig.getDevice('Stage').getConfigurationSetting('micronsPerPixel');
            obj.yTraj = yTraj .* 3.3/obj.rig.getDevice('Stage').getConfigurationSetting('micronsPerPixel');
            
            % Load the fixations for the image.
            f = load([obj.pkgDir,'\doves\fixations\', obj.imageName, '.mat']);
            obj.subjectName = f.subj_names_list{obj.im.FEMdata(obj.stimulusIndex).SubjectIndex};
            
            % Get the magnification factor. Exps were done with each pixel
            % = 1 arcmin == 1/60 degree; 200 um/degree...
            if obj.manualMagnification > 1
                obj.magnificationFactor = obj.manualMagnification;
            else
                obj.magnificationFactor = round(1/60*200/obj.rig.getDevice('Stage').getConfigurationSetting('micronsPerPixel'));
            end
            
            %compute center contrast trajectories for integrate contrast
            %manipulations...
            obj.centerContrasts = zeros(1,length(obj.xTraj));
            %go from rig pixels to image pixels for indexing into
            %VH image. Each VH pixel is ~1 arcmin = 3.3 microns on
            %primate retina

            imagePatchX = round(obj.canvasSize(1)*obj.rig.getDevice('Stage').getConfigurationSetting('micronsPerPixel')/3.3); %VH pixels displayed in the whole canvas (x)
            imagePatchY = round(obj.canvasSize(2)*obj.rig.getDevice('Stage').getConfigurationSetting('micronsPerPixel')/3.3); %VH pixels displayed in the whole canvas (y)

            %account for flips in stage presentation versus indexing.
            %xy flipped for stage shifting, and y is flipped for
            %indexing convention in matlab. Y flips cancel.
            centerSigmaVHPix = round(obj.centerSigma*obj.rig.getDevice('Stage').getConfigurationSetting('micronsPerPixel')/3.3);

            %2 stdev width of RF is aperture size
            obj.weightingFxn = fspecial('gaussian', centerSigmaVHPix*2, centerSigmaVHPix);
            filtSizeX = size(obj.weightingFxn, 1);
            filtSizeY = size(obj.weightingFxn, 2);
            [rr, cc] = meshgrid(1:filtSizeX,1:filtSizeY);
            apertureIndex = sqrt((rr-round(filtSizeX/2)).^2+(cc-round(filtSizeY/2)).^2)<=centerSigmaVHPix;
            obj.weightingFxn = obj.weightingFxn .* apertureIndex;
            obj.weightingFxn = obj.weightingFxn./sum(obj.weightingFxn(:)); %sum to one
             
            % calculate equivalent contrast for each frame (in VH pixels)
            for t=1:length(obj.centerContrasts) %frame by frame, pull out rectangle centered over fixation point
                fixX = xTraj(t)+size(img, 2)/2; fixY = yTraj(t)+size(img, 1)/2; %center of fixation
                %pull out current frame of stim, then do whatever
                %contrast integration computation selected... 
                currentFrame = img(round(fixY-filtSizeY/2+1):round(fixY+filtSizeY/2),...
                    round(fixX-filtSizeX/2+1):round(fixX+filtSizeX/2));
                obj.centerContrasts(t) = (sum(currentFrame(:).*obj.weightingFxn(:)))./255; %INTENSITY (0-1)
            end
            
        end
        
        function p = createPresentation(obj)
            p = stage.core.Presentation((obj.preTime + obj.stimTime + obj.tailTime) * 1e-3);
            p.setBackgroundColor(obj.backgroundIntensity);
            
            centerSigmaPix = round(obj.centerSigma*obj.rig.getDevice('Stage').getConfigurationSetting('micronsPerPixel'));
            if (~rem(obj.numEpochsCompleted, 2))
                % Doves movie
                scene = stage.builtin.stimuli.Image(obj.imageMatrix);
                scene.size = [size(obj.imageMatrix,2) size(obj.imageMatrix,1)]*obj.magnificationFactor;
                p0 = obj.canvasSize/2;
                scene.position = p0;

                scene.setMinFunction(GL.NEAREST);
                scene.setMagFunction(GL.NEAREST);

                % Add the stimulus to the presentation.
                p.addStimulus(scene);

                %apply eye trajectories to move image around
                scenePosition = stage.builtin.controllers.PropertyController(scene,...
                    'position', @(state)getScenePosition(obj, state.time - (obj.preTime+obj.waitTime)/1e3, p0));
                %Add the controller.
                p.addController(scenePosition);

            else
                % Create center that modulates according to contrast
                % integration
                scene = stage.builtin.stimuli.Ellipse();
                scene.position = obj.canvasSize/2;
                scene.color = 0; %obj.backgroundIntensity;
                scene.radiusX = centerSigmaPix;
                scene.radiusY = centerSigmaPix;
                p.addStimulus(scene)
                contrastLevel = stage.builtin.controllers.PropertyController(scene,...
                    'color',@(state)getContrastLevel(obj, state.time - obj.preTime/1e3));
                p.addController(contrastLevel);
            
            end
            
            % stimulus timing
            sceneVisible = stage.builtin.controllers.PropertyController(scene, 'visible', ...
                @(state)state.time >= obj.preTime * 1e-3 && state.time < (obj.preTime + obj.stimTime) * 1e-3);
            p.addController(sceneVisible);
            
            % Aperture
            aperture = stage.builtin.stimuli.Rectangle();
            aperture.position = obj.canvasSize/2;
            aperture.color = obj.backgroundIntensity;
            aperture.size = obj.canvasSize;
            [x,y] = meshgrid(linspace(-obj.canvasSize(1)/2,obj.canvasSize(1)/2,obj.canvasSize(1)), ...
                linspace(-obj.canvasSize(2)/2,obj.canvasSize(2)/2,obj.canvasSize(2)));
            distanceMatrix = sqrt(x.^2 + y.^2);
            circle = uint8((distanceMatrix >= centerSigmaPix) * 255);
            mask = stage.core.Mask(circle);
            aperture.setMask(mask);
            p.addStimulus(aperture); %add aperture
            
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
            
            function i = getContrastLevel(obj, time)
                if time < 0
                    i = obj.backgroundIntensity;
                elseif time > obj.timeTraj(end) %out of eye trajectory, hang on last frame
                    i = obj.backgroundIntensity;
                else %within eye trajectory and stim time
                    i = interp1(obj.timeTraj,obj.centerContrasts,time);
                end
            end
             
        end
        
        function prepareEpoch(obj, epoch)
            prepareEpoch@manookinlab.protocols.ManookinLabStageProtocol(obj, epoch);
                    
            if length(unique(obj.stimulusIndices)) > 1
                % Set the current stimulus trajectory.
                obj.stimulusIndex = obj.stimulusIndices(floor(mod(obj.numEpochsCompleted/2,...
                    length(obj.stimulusIndices)) + 1));
                obj.getImageSubject();
            end
            
            % Save the parameters.
            epoch.addParameter('centerContrasts', obj.centerContrasts);
            epoch.addParameter('stimulusIndex', obj.stimulusIndex);
            epoch.addParameter('imageName', obj.imageName);
            epoch.addParameter('subjectName', obj.subjectName);
            epoch.addParameter('backgroundIntensity', obj.backgroundIntensity);
            epoch.addParameter('magnificationFactor', obj.magnificationFactor);
            epoch.addParameter('currentStimSet',obj.currentStimSet);
        end
        
        % Same presentation each epoch in a run. Replay.
        function controllerDidStartHardware(obj)
            controllerDidStartHardware@edu.washington.riekelab.protocols.RiekeLabProtocol(obj);
            if (obj.numEpochsCompleted >= 1) && (obj.numEpochsCompleted < obj.numberOfAverages) && (length(unique(obj.stimulusIndices)) == 1)
                obj.rig.getDevice('Stage').replay
            else
                obj.rig.getDevice('Stage').play(obj.createPresentation());
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
