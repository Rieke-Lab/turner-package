function [Kc,sigmaC,Ks,sigmaS,baseFiring] = fitDoGAreaSummation(spotSizes,responses,params0)
    % [Kc,sigmaC,Ks,sigmaS] = fitDoGAreaSummation(spotSizes,responses,params0)
    % MHT 05/2016
    LB = [0, 0, 0, 0, 0]; UB = [Inf Inf Inf Inf Inf];
    fitOptions = optimset('MaxIter',2000,'MaxFunEvals',600*length(LB),'Display','off', 'Algorithm','levenberg-marquardt');
    
    [params, ~, ~]=lsqcurvefit(@edu.washington.riekelab.turner.utils.DoGAreaSummation,params0,spotSizes,responses,LB,UB,fitOptions);
    Kc = params(1); sigmaC = params(2); Ks = params(3); sigmaS = params(4); baseFiring=params(5);
end
