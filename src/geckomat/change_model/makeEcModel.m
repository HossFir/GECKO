function model = makeEcModel(model, geckoLight, modelAdapter)
% makeEcModel
%   Expands a conventional genome-scale model (in RAVEN format) with enzyme
%   information and prepares the reactions for integration of enzyme usage
%   coefficients. This function contains all the steps that need to be done
%   to get a basic ec-model, without incorporating any kcat values or
%   constraints yet. This function should only have to be run once for a
%   model.
%
% Input:
%   model        a model in RAVEN format
%   geckoLight   true if a simplified GECKO light model should be generated.
%                (Optional, default is false).
%   modelAdapter a loaded model adapter (Optional, will otherwise use the
%                default model adapter).
%
% Ouput:
%   model           a model with a model.ec structure where enzyme and kcat
%                   information are stored. Protein pseudometabolites and
%                   their draw reactions are added to the model, but their
%                   usage is not yet implemented (due to absent kcat values
%                   at this stage).
%
% The function goes through the following steps:
%   1.  Remove gene associations from pseudoreactions.
%   2.  Invert irreversible backwards reactions.
%   3.  Correct 'rev' vector to match lb and ub vectors.
%   4.  Convert to irreversible model (splits reversible reactions).
%   5.  [Skipped with geckoLight:] Expand model to split reactions with
%       'OR' in grRules (each reaction is then catalyzed by one enzyme
%       (complex).
%   6.  [Skipped with geckoLight:] Sort identifiers (so that split
%       reactions remain close to each other, not real function, just makes
%       it tidier.
%   7.  Make empty model.ec structure, that will contain enzyme and kcat
%       information. One entry per reaction, where isoenzymes have multiple
%       entries. This model.ec structure will later be populated with kcat
%       values. For geckoLight the structure is different, where each
%       reaction can have multiple isozymes.
%   8.  Add enzyme information fields to model.ec structure: MW, sequence.
%   9.  Populate model.ec structure (from step 8) with information from
%       each reaction.
%   10. [Skipped with geckoLight:] Add proteins as pseudometabolites.
%   11. Add prot_pool pseudometabolite.
%   12. [Skipped with geckoLight:] Add usage reactions for the protein
%       pseudometabolites, replenishing from the protein pool (default, can
%       be changed to consider proteomics data at later stage)
%   13. Add protein pool reaction, without upper bound.
%
%   Note that while protein pseudometabolites, draw & pool reactions might
%   be added to the model, the enzyme usage is not yet incorporated in each
%   metabolic reaction, so enzymes will not be used. applyKcatConstraints
%   incorporates protein pseudometabolites in reactions as enzyme usages by
%   applying the specified kcats as constraints.
%
%The EC structure looks as follows
% Attributes:
%   geckoLight: 0 if full model, 1 if light
%         rxns: reaction identifiers that correspond to model.rxns
%         kcat: kcat values - not set here
%       source: specifies where the kcats come from - not set here
%        notes: notes that can be set by downstream functions - not set
%               here
%      eccodes: enzyme codes for each enzyme - not set here
%        genes: the genes involved in the kcats - not necessarily the
%               same as model.genes, since some genes may not be found in
%               databases etc.
%      enzymes: Uniprot protein identifiers for the genes
%           mw: molecular weights of the enzymes
%     sequence: sequence of the genes/enzymes
%        concs: concentrations of the enzymes - not set here
%    rxnEnzMat: matrix of enzymes and rxns
%
% The full model is split on all ORs in the GPRs, meaning that the
% reactions will be duplicated for each isozyme. Only the rxns with genes
% are added. The fields rxns, eccodes, kcat, source and notes will
% therefore have one entry per reaction. The fields genes, enzymes, mw,
% sequence and concs will have one entry per gene. The rxnEnzMat is a
% matrix with reactions and genes, mapping which genes are connected to
% which reaction (where isozymes have different reactions).
%
% The light model works a bit differently. The model has the same number of
% rxns as the original model, but expanded since it is reversible + one the
% extra prot maintenance rxn and one extra prot_pool rxn. However, the ec
% fields rxns, eccodes, kcat, source and notes are duplicated for each
% isozyme, sorted the same way as model.rxns. So, in model.ec.rxns, the
% same reaction will appear several times after one another, one entry per
% izozyme, with corresponding values for that isozyme. These fields
% therefore have the same length as for the full model. The fields genes,
% enzymes, mw, sequence and concs are the same here as in the full model.
% The rxnEnzMat maps the model.ec.rxns entries to genes and is therefore of
% the same size as for the full model.

if nargin<2
    geckoLight=false;
elseif ~islogical(geckoLight) && ~(geckoLight == 0) && ~(geckoLight == 1)
    error('geckoLight should be either true or false')
end

if nargin < 3 || isempty(modelAdapter)
    modelAdapter = ModelAdapterManager.getDefaultAdapter();
    if isempty(modelAdapter)
        error('Either send in a modelAdapter or set the default model adapter in the ModelAdapterManager.')
    end
end
params = modelAdapter.getParameters();

if geckoLight
    ec.geckoLight=true;
else
    ec.geckoLight=false;
end

%Check if model is in RAVEN format
if any(isfield(model,{'rules','modelID'}))
    error(['The model is likely loaded using COBRA Toolbox readCbModel(). Instead, use ' ...
           'RAVEN Toolbox importModel(). Alternatively, you can also convert the ', ...
           'model in MATLAB using ravenCobraWrapper().'])
end

%Check for conflicting reaction and metabolite identifiers
conflictId = startsWith(model.mets,'prot_');
if any(conflictId)
    error('The identifiers in model.mets are not allowed to start with ''prot_''.')
end
conflictId = startsWith(model.rxns,{'usage_prot_','prot_pool'}) | ...
             endsWith(model.rxns,'_REV') | ...
             ~cellfun(@isempty,regexp(model.rxns,'_EXP_\d+$'));
if any(conflictId)
    error(['The identifiers in model.rxns are not allowed to start with ''usage_prot'' ' ...
           'or ''prot_pool'', or end with ''_REV'' or ''_EXP_[digit]''.'])
end

uniprotDB = loadDatabases('uniprot', modelAdapter);
uniprotDB = uniprotDB.uniprot;

%1: Remove gene rules from pseudoreactions (if any):
for i = 1:length(model.rxns)
    if endsWith(model.rxnNames{i},' pseudoreaction')
        model.grRules{i}      = '';
        model.rxnGeneMat(i,:) = zeros(1,length(model.genes));
    end
end

%2: Swap direction of reactions that are defined to only carry negative flux
to_swap=model.lb < 0 & model.ub == 0;
model.S(:,to_swap)=-model.S(:,to_swap);
model.ub(to_swap)=-model.lb(to_swap);
model.lb(to_swap)=0;

%3: Correct rev vector: true if LB < 0 & UB > 0, or it is an exchange reaction:
model.rev = false(size(model.rxns));
for i = 1:length(model.rxns)
    if (model.lb(i) < 0 && model.ub(i) > 0) || sum(model.S(:,i) ~= 0) == 1
        model.rev(i) = true;
    end
end

%4: Make irreversible model (appends _REV to reaction IDs to indicate reverse
%reactions)
[~,exchRxns] = getExchangeRxns(model);
nonExchRxns = model.rxns;
nonExchRxns(exchRxns) = [];
model=convertToIrrev(model, nonExchRxns);

%5: Expand model, to separate isoenzymes (appends _EXP_* to reaction IDs to
%indicate duplication)
if ~geckoLight
    model=expandModel(model);
end

%6: Sort reactions, so that reversible and isoenzymic reactions are kept near
if ~geckoLight
    model=sortIdentifiers(model);
end

%7: Make ec-extension structure, one for gene-associated reaction.
%   The structure is different for light and full models
rxnWithGene  = find(sum(model.rxnGeneMat,2));
if ~geckoLight
    ec.rxns      = model.rxns(rxnWithGene);
    emptyCell    = cell(numel(rxnWithGene),1);
    emptyCell(:) = {''};
    emptyVect    = zeros(numel(rxnWithGene),1);
    
    ec.kcat      = emptyVect;
    ec.source    = emptyCell; % Strings, like 'dlkcat', 'manual', 'brenda', etc.
    ec.notes     = emptyCell; % Additional comments
    ec.eccodes   = emptyCell;
    ec.concs     = emptyVect;
else
    %Different strategy for GECKO light: Each reaction can exist multiple times in 
    %ec.rxns and similar fields - one time per isozyme. The number of copies is
    %the number of ORs in the GPR + 1
    numOrs = count(model.grRules(rxnWithGene), ' or ');
    cpys = numOrs + 1;
    prevNumRxns = length(numOrs);
    cpyIndices = repelem(rxnWithGene, cpys);
    %loop through and add a prefix with an isozyme index to the rxns
    %we just give a fixed-length number as prefix, and assume that 999 is enough
    tmpRxns = model.rxns(cpyIndices); %now they have no prefix
    newRxns = tmpRxns;
    
    %add the prefix
    nextIndex = 1;
    for i = 1:numel(model.rxns)
        localRxnIndex = 1;
        if nextIndex <= length(tmpRxns) && strcmp(model.rxns(i), tmpRxns(nextIndex))
            while true
                tmp = compose('%03d_',localRxnIndex);
                newRxns{nextIndex} = [tmp{1} tmpRxns{nextIndex}];
                localRxnIndex = localRxnIndex + 1;
                if (localRxnIndex >= 1000)
                    error('Increase index size to 10000 - error in the code.'); %this should never happen, we don't have > 999 isozymes
                end
                nextIndex = nextIndex + 1;
                if  nextIndex > length(tmpRxns) || ~strcmp(model.rxns(i), tmpRxns(nextIndex))
                    break;
                end
            end
        end
    end

    ec.rxns      = newRxns;
    
    emptyCell    = cell(numel(ec.rxns),1);
    emptyCell(:) = {''};
    emptyVect    = zeros(numel(ec.rxns),1);

    ec.kcat      = emptyVect;
    ec.source    = emptyCell; % Strings, like 'dlkcat', 'manual', 'brenda', etc.
    ec.notes     = emptyCell; % Additional comments
    ec.eccodes   = emptyCell;
    ec.concs     = emptyVect;
end
    
%8: Gather enzyme information via UniprotDB
uniprotCompatibleGenes = modelAdapter.getUniprotCompatibleGenes(model.genes);
[Lia,Locb]      = ismember(uniprotCompatibleGenes,uniprotDB.genes);
if any(~Lia)
    disp(['Cannot find ' num2str(numel(find(~Lia))) ' of ' num2str(numel(uniprotCompatibleGenes)) ...
          ' genes in local UniProt DB, these will not be enzyme-constrained.'])
end
ec.genes        = model.genes(Lia); %Will often be duplicate of model.genes, but is done here to prevent issues when it is not.
ec.enzymes      = uniprotDB.ID(Locb(Lia));
ec.mw           = uniprotDB.MW(Locb(Lia));
ec.sequence     = uniprotDB.seq(Locb(Lia));
%Additional info
ec.concs        = nan(numel(ec.genes),1); % To be filled with proteomics data when available

%9: Only parse rxns associated to genes
if ~geckoLight
    ec.rxnEnzMat = zeros(numel(rxnWithGene),numel(ec.genes)); % Non-zeros will indicate the number of subunits
    for r=1:numel(rxnWithGene)
        rxnGenes   = model.genes(find(model.rxnGeneMat(rxnWithGene(r),:)));
        [~,locEnz] = ismember(rxnGenes,ec.genes); % Could also parse directly from rxnGeneMat, but some genes might be missing from Uniprot DB
        if locEnz ~= 0
            ec.rxnEnzMat(r,locEnz) = 1; %Assume 1 copy per subunit or enzyme, can be modified later
        end
    end
else
    %For light models, we need to split up all GPRs
    ec.rxnEnzMat = zeros(numel(ec.rxns),numel(ec.genes)); % Non-zeros will indicate the number of subunits
    nextIndex = 1;
    %For full model generation, the GPRs are controlled in expandModel, but 
    %here we need to make an explicit format check
    indexes2check = findPotentialErrors(model.grRules,false,model);
    if ~isempty(indexes2check) 
        disp('For Human-GEM, these reactions can be corrected using simplifyGrRules.');
    end
    
    for i=1:prevNumRxns
        %ind is the index in the model, not to confuse with the index in the ec struct (i),
        %which only contains reactions with GPRs.
        ind = rxnWithGene(i); 
        %Get rid of all '(' and ')' since I'm not looking at complex stuff
        %anyways
        geneString=model.grRules{ind};
        geneString=strrep(geneString,'(','');
        geneString=strrep(geneString,')','');
        geneString=strrep(geneString,' or ',';');
        
        if (numOrs(i) == 0)
            geneNames = {geneString};
        else
            %Split the string into gene names
            geneNames=regexp(geneString,';','split');
        end
        
        %Now loop through the isozymes and set the rxnGeneMat
        for j = 1:length(geneNames)
            %Find the gene in the gene list If ' and ' relationship, first
            %split the genes
            fnd = strfind(geneNames{j},' and ');
            if ~isempty(fnd)
                andGenes=regexp(geneNames{j},' and ','split');
                ec.rxnEnzMat(nextIndex,ismember(ec.genes,andGenes)) = 1; %should be subunit stoichoimetry
            else
                ec.rxnEnzMat(nextIndex,ismember(ec.genes,geneNames(j)))=1;%should be subunit stoichoimetry
            end
            nextIndex = nextIndex + 1;
        end
    end
end

%10: Add proteins as pseudometabolites
if ~geckoLight
    [proteinMets.mets, uniprotSortId] = sort(ec.enzymes);
    proteinMets.mets         = strcat('prot_',proteinMets.mets);
    proteinMets.metNames     = proteinMets.mets;
    proteinMets.compartments = 'c';
    if isfield(model,'metMiriams')
        proteinMets.metMiriams   = repmat({struct('name',{{'sbo'}},'value',{{'SBO:0000252'}})},numel(proteinMets.mets),1);
    end
    proteinMets.metNotes     = repmat({'Enzyme-usage pseudometabolite'},numel(proteinMets.mets),1);
    model = addMets(model,proteinMets);
end

%11: Add protein pool pseudometabolite
pool.mets         = 'prot_pool';
pool.metNames     = pool.mets;
pool.compartments = 'c';
pool.metNotes     = 'Enzyme-usage protein pool';
model = addMets(model,pool);

%13: Add protein usage reactions.
if ~geckoLight
    usageRxns.rxns            = strcat('usage_',proteinMets.mets);
    usageRxns.rxnNames        = usageRxns.rxns;
    usageRxns.mets            = cell(numel(usageRxns.rxns),1);
    usageRxns.stoichCoeffs    = cell(numel(usageRxns.rxns),1);
    for i=1:numel(usageRxns.mets)
        usageRxns.mets{i}         = {'prot_pool',proteinMets.mets{i}};
        usageRxns.stoichCoeffs{i} = [-1,1];
    end
    usageRxns.lb              = zeros(numel(usageRxns.rxns),1);
    usageRxns.grRules         = ec.genes(uniprotSortId);
    model = addRxns(model,usageRxns);
end

%12: Add protein pool reaction (with open UB)
poolRxn.rxns            = 'prot_pool_exchange';
poolRxn.rxnNames        = poolRxn.rxns;
poolRxn.mets            = {'prot_pool'};
poolRxn.stoichCoeffs    = {1};
poolRxn.lb              = 0;
model = addRxns(model,poolRxn);

model.ec=ec;
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%Function that gets the model field grRules and returns the indexes of the
%rules in which the pattern ") and (" is present.
%Copied from standardizeGrRules
% TODO: Make this an accessible function in a separate file in RAVEN and remove this
%implementation.
function indexes2check = findPotentialErrors(grRules,embedded,model)
indxs_l       = find(~cellfun(@isempty,strfind(grRules,') and (')));
indxs_l_L     = find(~cellfun(@isempty,strfind(grRules,') and')));
indxs_l_R     = find(~cellfun(@isempty,strfind(grRules,'and (')));
indexes2check = vertcat(indxs_l,indxs_l_L,indxs_l_R);
indexes2check = unique(indexes2check);

if ~isempty(indexes2check)
    
    if embedded
        EM = 'Potentially problematic ") AND (" in the grRules for reaction(s): ';
        dispEM(EM,false,model.rxns(indexes2check),true)
    else
        STR = 'Potentially problematic ") AND (", ") AND" or "AND ("relat';
        STR = [STR,'ionships found in\n\n'];
        for i=1:length(indexes2check)
            index = indexes2check(i);
            STR = [STR '  - grRule #' model.rxns{index} ': ' grRules{index} '\n'];
        end
        STR = [STR,'\n This kind of relationships should only be present '];
        STR = [STR,'in  reactions catalysed by complexes of isoenzymes e'];
        STR = [STR,'.g.\n\n  - (G1 or G2) and (G3 or G4)\n\n For these c'];
        STR = [STR,'ases modify the grRules manually, writing all the po'];
        STR = [STR,'ssible combinations e.g.\n\n  - (G1 and G3) or (G1 a'];
        STR = [STR,'nd G4) or (G2 and G3) or (G2 and G4)\n\n For other c'];
        STR = [STR,'ases modify the correspondent grRules avoiding:\n\n '];
        STR = [STR,' 1) Overall container brackets, e.g.\n        "(G1 a'];
        STR = [STR,'nd G2)" should be "G1 and G2"\n\n  2) Single unit en'];
        STR = [STR,'zymes enclosed into brackets, e.g.\n        "(G1)" s'];
        STR = [STR,'hould be "G1"\n\n  3) The use of uppercases for logi'];
        STR = [STR,'cal operators, e.g.\n        "G1 OR G2" should be "G'];
        STR = [STR,'1 or G2"\n\n  4) Unbalanced brackets, e.g.\n        '];
        STR = [STR,'"((G1 and G2) or G3" should be "(G1 and G2) or G3"\n'];
        warning(sprintf(STR))
    end
end
end

