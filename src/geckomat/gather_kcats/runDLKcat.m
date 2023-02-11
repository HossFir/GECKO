function runDLKcat(DLKcatFile, modelAdapter, DLKcatPath, pythonPath, pipPath)
% runDLKcat
%   Runs DLKcat to predict kcat values.
%
% Input
%   DLKcatFile      path to the DLKcat.tsv file (including file name), as
%                   written by writeDLKcatFile. Once DLKcat is succesfully
%                   run, the DLKcatFile will be overwritten with the DLKcat
%                   output. Optional, otherwise the file location will be
%                   assumed to be in the model-specific 'data' sub-folder
%                   taken from modelAdapter (e.g.
%                   GECKO/userData/ecYeastGEM/data/DLKcat.tsv)
%   modelAdapter    a loaded model adapter. (Optional, will otherwise use
%                   the default model adapter)
%   DLKcatPath      path where DLKcat is/will be installed. (Optional,
%                   defaults to GECKO/dlkcat)
%   pythonPath      path to python binary. (Optional, defaults to use the
%                   python that is available via terminal)
%   pipPath         path to pip binary. (Optional, defaults to use the pip
%                   that is available via terminal)
%
%   NOTE: Requires Python 3 to be installed. If not present, it will also
%   install pip, pipenv and other DLKcat dependencies.

%Get the GECKO path
geckoPath=findGECKOroot();

if nargin < 5 || isempty(pipPath)
    pipPath = '';
end

if nargin < 4 || isempty(pythonPath)
    pythonPath = '';
end

if nargin < 3 || isempty(DLKcatPath)
    DLKcatPath = fullfile(geckoPath,'dlkcat');
end

if nargin < 2 || isempty(modelAdapter)
    modelAdapter = ModelAdapterManager.getDefaultAdapter();
    if isempty(modelAdapter)
        error('Either send in a modelAdapter or set the default model adapter in the ModelAdapterManager.')
    end
end
params = modelAdapter.params;

if nargin < 1 || isempty(DLKcatFile)
    DLKcatFile = fullfile(params.path,'data','DLKcat.tsv');
end

if ~exist(fullfile(DLKcatPath,'DLKcat.py'),'file')
    if ~exist(fullfile(DLKcatPath),'dir')
        mkdir(fullfile(DLKcatPath));
    end
    disp('=== Downloading DLKcat...')
    %OneDrive URL below is temporary and expires 18 Feb. To be replaced
    %with URL to GitHub once GECKO3 is released.
    packageURL = 'https://chalmers-my.sharepoint.com/:u:/g/personal/eduardk_chalmers_se/ESrmFfgjTCVNgihPOIgEPg0BfTuOPuj4Deav-jWWG-Royg?e=iAIUta&download=1';
    %packageURL = 'https://github.com/SysBioChalmers/GECKO/releases/download/v3.0.0/dlkcat_package.zip';
    websave(fullfile(DLKcatPath,'dlkcat_package.zip'),packageURL);
    unzip(fullfile(DLKcatPath,'dlkcat_package.zip'),DLKcatPath);
    delete(fullfile(DLKcatPath,'dlkcat_package.zip'));
end

%% Check and install requirements
% On Mac, python might not be properly loaded if MATLAB is started via
% launcher and not terminal. 
if ismac && isempty(pythonPath)
    global MACZPROFILEPATH
    if isempty(MACZPROFILEPATH)
        try
            [~, zPath] = system("awk '/PATH=/{print}' ~/.zprofile");
            zPath = strip(strsplit(zPath,':'));
            zPath = zPath(contains(zPath,'Python.framework'));
            zPath = regexprep(zPath{1}, 'PATH="', '');
            setenv('PATH', strcat(zPath, ':', getenv("PATH")));
            MACZPROFILEPATH = 'set';
        catch
        end
    end
end

binEnd = '';
if ispc
    binEnd = '.exe';
end

% Python
three = ''; %suffix (python vs. python3)
if isempty(pythonPath)
    [checks.python.status, checks.python.out] = system('python --version');
    if checks.python.status ~= 0 || ~startsWith(checks.python.out,'Python 3.')
        [checks.python.status, checks.python.out] = system('python3 --version');
        if checks.python.status == 0
            three = '3';
            if ispc
                [~, pythonPath] = system('where python3');
                pythonPath = regexprep(pythonPath,'\n.*','');
            else
                [~, pythonPath] = system('which python3');
            end
        else
            error('Cannot find Python 3.')
        end
    elseif startsWith(checks.python.out,'Python 3.')
        if ispc
            [~, pythonPath] = system('where python');
            pythonPath = regexprep(pythonPath,'\n.*','');
        else
            [~, pythonPath] = system('which python');
        end
    end
end
if endsWith(pythonPath,'.exe')
    pythonPath = pythonPath(1:end-4);
end
if endsWith(strtrim(pythonPath),'python3')
    three = '3';
    pythonPath = strtrim(pythonPath);
    pythonPath = pythonPath(1:end-7);
elseif endsWith(strtrim(pythonPath),'python')
    pythonPath = strtrim(pythonPath);
    pythonPath = pythonPath(1:end-6);
else
    error('pythonPath should end with either "python", "python.exe", "python3" or "python3.exe".')
end

% add the Python package dir to PATH.
if ispc
    [~,packageDir]=system([pythonPath 'python' three ' -m site --user-site']);
    packageDir=strip(regexprep(packageDir,'site-packages','Scripts'));
    setenv('PATH',strcat(getenv("PATH"), ';',  packageDir, ';', pythonPath, 'Scripts/'));
else
    [~,packageDir]=system([pythonPath 'python' three ' -m site --user-base']);
    setenv('PATH',strcat(packageDir, '/bin/', ':', getenv("PATH")));
end

% pip
pipThree = three;
if isempty(pipPath)
    [checks.pip.status, checks.pip.out] = system(['pip' pipThree ' --version']);
    if checks.pip.status ~= 0
        disp('=== Installing pip...')  
        status = system([pythonPath 'python' three ' -m ensurepip --upgrade']);
        if status == 0
            [checks.pip.status, checks.pip.out] = system(['pip' pipThree ' --version']);
        end
        if status ~= 0 || checks.pip.status ~=0
            error('Cannot find pip and automated installation failed')
        end
    end
else
    if endsWith(pipPath,'.exe')
        pipPath = pipPath(1:end-4);
    end
    if endsWith(pipPath,'pip3')
        pipThree = '3';
        pipPath = pipPath(1:end-4);
    elseif endsWith(pipPath,'pip')
        pipPath = pipPath(1:end-3);
    else
        error('pipPath should end with either "pip", "pip.exe", "pip3" or "pip3.exe".')
    end
end

% pipenv
% Always install fresh, as it is otherwise too tricky to match pipenv
% binary with the correct python and pip versions if multiple python and
% pip versions are present.
disp('=== Installing pipenv...')    
    status = system([pipPath 'pip' pipThree ' install pipenv']);
    if status == 0
        [checks.pipenv.status, checks.pipenv.out] = system('pipenv --version');
        if checks.pipenv.status ~= 0
            [checks.pipenv.status, checks.pipenv.out] = system('pipenv --version');
            if checks.pipenv.status ~= 0
                error('After installing pipenv, it cannot be found in the PATH')
            end
        end
    else
        error('Unable to install pipenv')
    end

currPath = pwd();
cd(DLKcatPath);

[checks.dlkcatenv.status, checks.dlkcatenv.out] = system('pipenv --py');
if checks.dlkcatenv.status ~= 0
    disp('=== Preparing DLKcat environment...')
    system(['pipenv install -r requirements.txt --python ' pythonPath 'python' three binEnd], '-echo');
end
disp('=== Running DLKcat prediction, this may take several minutes...')
% In the next line, pythonPath does not need to be specified, because it is
% already mentioned when building the virtualenv.
dlkcat.status = system(['pipenv run python DLKcat.py ' DLKcatFile ' DLKcatOutput.tsv'],'-echo');
cd(currPath);

if dlkcat.status == 0
    movefile('DLKcatOutput.tsv',DLKcatFile);
    cd(currPath);
else
    cd(currPath);
    error(['DLKcat encountered an error. This may be due to issues with the ' ...
           'pipenv. It may help to run system(''pipenv --rm'') in your ' ...
           'dlkcat folder (do not skip this step), and afterwards completely ' ...
           'delete the dlkcat folder and rerun runDLKcat().'])
end 
end
