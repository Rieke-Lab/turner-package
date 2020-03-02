classdef MeanPlusGrating < edu.washington.riekelab.protocols.RiekeLabStageProtocol
    % MeanPlusGrating: raise a mean value to grating stimuli
    % modified from Max's ContrastReversingGrating.m and
    % MeanPlusContrastimage.m
    
    % V1: manually set a mean value; bar width is determined by a array
    % input
    % Try to match stimulation parameter to those in
    % MeanPlusContrastImage.m for future comparison purpose
    
    properties
        preTime = 200 % ms
        stimTime = 200 % ms
        tailTime = 200 % ms
        meanIntensity = 0.6 % (0-1), uniform
        apertureDiameter = 200 % um
        rfSigmaCenter = 50 % (um) Enter from fit RF
        minbarWidth = 20; % minimum bar width um
        rotation = 0; % deg
        backgroundIntensity = 0.3 % (0-1)
        centerOffset = [0, 0] % [x,y] (um)
        numBarwidth = 5; % the number of bar width 
        onlineAnalysis = 'none'
        numberOfAverages = uint16(40) % number of epochs to queue
        linearIntegrationFunction = 'gaussian center' % small error due to pixel int
        maskDiameter = 0; % place holder
        amp
    end
    properties (Hidden)
        ampType
        onlineAnalysisType = symphonyui.core.PropertyType('char', 'row', {'none', 'extracellular', 'exc', 'inh'})
        currentBarWidth
        linearIntegrationFunctionType = symphonyui.core.PropertyType('char', 'row', {'gaussian center','uniform'})
        centerOffsetType = symphonyui.core.PropertyType('denserealdouble', 'matrix')
        barWidthSequence
        % saved to each epoch
        stimulusTag
        equimean % equivalent intensity
        int_error = 0.03; % error space due to pixels are int
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
                'groupBy',{'stimulusTag'});
            obj.showFigure('edu.washington.riekelab.turner.figures.FrameTimingFigure',...
                obj.rig.getDevice('Stage'), obj.rig.getDevice('Frame Monitor'));
            if ~strcmp(obj.onlineAnalysis,'none')
                obj.showFigure('edu.washington.riekelab.yu.figures.MeanPlusGratingFigure',...
                obj.rig.getDevice(obj.amp),'recordingType',obj.onlineAnalysis,...
                'preTime',obj.preTime,'stimTime',obj.stimTime);
            end
            %obj.barWidthSequence = linspace(obj.minbarWidth,obj.rig.getDevice('Stage').um2pix(obj.apertureDiameter)/2,obj.numBarwidth);

            obj.barWidthSequence = ones(1,2*obj.numBarwidth);
            % alternating the dark and bright bars
            obj.barWidthSequence(1:2:2*obj.numBarwidth) = linspace(obj.minbarWidth,obj.apertureDiameter/2,obj.numBarwidth);
            obj.barWidthSequence(2:2:2*obj.numBarwidth) = -linspace(obj.minbarWidth,obj.apertureDiameter/2,obj.numBarwidth);
        end
        
         function prepareEpoch(obj, epoch)
            prepareEpoch@edu.washington.riekelab.protocols.RiekeLabStageProtocol(obj, epoch);
            stimInd = mod(obj.numEpochsPrepared - 1,3);
            if stimInd == 0 % show linear equivalent intensity
                obj.stimulusTag = 'intensity';
            elseif stimInd == 1 %  show remaining spatial contrast (image - intensity)
                obj.stimulusTag = 'contrast';
            elseif stimInd == 2 %  show image
                obj.stimulusTag = 'contrast';
            end
            barindex = mod(floor((obj.numEpochsPrepared - 1)/3),obj.numBarwidth*2)+1;
            obj.currentBarWidth = obj.barWidthSequence(barindex);
            device = obj.rig.getDevice(obj.amp);
            duration = (obj.preTime + obj.stimTime + obj.tailTime) / 1e3;
            epoch.addDirectCurrentStimulus(device, device.background, duration, obj.sampleRate);
            epoch.addResponse(device);
            epoch.addParameter('backgroundIntensity', obj.backgroundIntensity);
            epoch.addParameter('stimulusTag', obj.stimulusTag);
            epoch.addParameter('currentBarWidth', obj.currentBarWidth);
        end
         
        function p = createPresentation(obj)
            canvasSize = obj.rig.getDevice('Stage').getCanvasSize();
            
            %convert from microns to pixels...
            apertureDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.apertureDiameter);
            centerOffsetPix = obj.rig.getDevice('Stage').um2pix(obj.centerOffset);
            %maskDiameterPix = obj.rig.getDevice('Stage').um2pix(obj.maskDiameter);
            currentBarWidthPix = obj.rig.getDevice('Stage').um2pix(obj.currentBarWidth);
            
            p = stage.core.Presentation((obj.preTime + obj.stimTime + obj.tailTime) * 1e-3); %create presentation of specified duration
            p.setBackgroundColor(obj.backgroundIntensity); % Set background intensity
            
            grate_height = -obj.int_error+edu.washington.riekelab.yu.utils.setGrateColor(obj.backgroundIntensity,obj.meanIntensity); 
            grateMatrix = edu.washington.riekelab.yu.utils.createGratings(obj.meanIntensity, grate_height,currentBarWidthPix,apertureDiameterPix);
            grateMatrix_image = uint8(grateMatrix.*255);
            
            sigmaC = obj.rfSigmaCenter ./ 3.3; %microns -> VH pixels
            %gaussian or uniform
            obj.equimean = edu.washington.riekelab.yu.utils.EquiMean(sigmaC,grateMatrix,obj.linearIntegrationFunction);
            grateMatrix_raw = uint8((grateMatrix - obj.equimean+obj.backgroundIntensity).*255);
         
            if strcmp(obj.stimulusTag,'image')
                scene = stage.builtin.stimuli.Image(grateMatrix_image);
            elseif strcmp(obj.stimulusTag,'intensity')
                scene = stage.builtin.stimuli.Rectangle();
                scene.color = obj.equimean;
            elseif strcmp(obj.stimulusTag,'contrast')
                scene = stage.builtin.stimuli.Image(grateMatrix_raw);
            end
            
            scene.size = [apertureDiameterPix apertureDiameterPix]; %scale up to canvas size
            scene.position = canvasSize/2 + centerOffsetPix;
            p.addStimulus(scene);
            sceneVisible = stage.builtin.controllers.PropertyController(scene, 'visible', ...
                    @(state)state.time >= obj.preTime * 1e-3 && state.time < (obj.preTime + obj.stimTime) * 1e-3);
            p.addController(sceneVisible);
            
            if  (obj.apertureDiameter > 0) % Create aperture
                aperture = stage.builtin.stimuli.Rectangle();
                aperture.position = canvasSize/2 + centerOffsetPix;
                aperture.color = obj.backgroundIntensity;
                aperture.size = [apertureDiameterPix, apertureDiameterPix];
                mask = stage.core.Mask.createCircularAperture(1, 1024); %circular aperture
                aperture.setMask(mask);
                p.addStimulus(aperture); %add aperture
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

