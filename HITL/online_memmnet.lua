-- Copyright (c) 2015-present, Facebook, Inc.
-- All rights reserved.
--
-- This source code is licensed under the BSD-style license found in the
-- LICENSE file in the root directory of this source tree. An additional grant
-- of patent rights can be found in the PATENTS file in the same directory.

require('torch')
local stringx=require("pl.stringx")
local online_memmnet={}
online_memmnet.Data=require("data")

function online_memmnet:Initial(params_)
    self.params=params_;
    self.Data:Initial(self.params)
    if self.params.dataset=="movieQA" then
        model.Data:constructLink()
    end
    self.candidate_pool={};
    self.Data:process_data(self.params)
    assert(self.params.dataset~=nil)
    if self.params.dataset=="movieQA" then
        self.params.token_size=200000
    else self.params.token_size=100;
    end
    self.word_table=
        nn.LookupTable(self.params.token_size,self.params.dimension):cuda();
    self.word_table:reset(self.params.init_weight)
    self.word_table.weight[1]:zero()
    self.LookUpTable=self:LookUpTable_();
    self.Modules={}
    self.Modules[1]=self.LookUpTable;

    grad_norm=0
    self.MeMM=self:MeMM_();
    if self.params.ReadModel then
        self:ReadExisitngModel()
    end
    self.n_instance=self.params.batch_size;
    self.total_reward=0;
    self.total_reward_instance=0;
    self.total_cost_FP=0;
    self.total_cost_RBI=0;
    self.total_instance_FP=0;
    self.total_instance_RBI=0;
    self.current_lr=self.params.lr;
    if self.params.REINFORCE then
        -- REINFORCE baseline
        self.baseline = nn.Linear(self.params.dimension, 1)
        self.baseline.weight:fill(0)
        self.baseline.bias:fill(0)
        self.baseline:cuda()
        self.mse = nn.MSECriterion()
        self.mse:cuda()
        -- REINFORCE regularizer
        self.regularizer = nn.Sequential()
        local tmp = nn.ConcatTable()
        tmp:add(nn.Identity())
        tmp:add(nn.Exp())
        self.regularizer:add(tmp)
        self.regularizer:add(nn.CMulTable()) -- p log p
        self.regularizer:add(nn.Sum(1, 1))
        self.regularizer:add(nn.Sum(1))
        self.regularizer:cuda()
    end
    self.gen_yes_list={
        "Yes, that is correct!",
        "Yes, that's right.",
        "Correct!",
        "That's right.",
        "That's correct.",
        "Yes!"
    }
    if self.params.FP then
        self:ReadNegativeResponses()
    end
    if self.params.dataset=="movieQA" then
        self.Data.trainData=self.Data:sortData(model.Data.trainData,"hist_x")
    end
end

function online_memmnet:ReadNegativeResponses()
    if self.params.FP then
        self.Data.NegResponse={};
        local open=io.open(self.params.IncorrectResponse,"r")
        local i=0
        while true do
            i=i+1;
            local line=open:read("*line");
            if line==nil then break end
            line=self.Data:process_string(line)
            if self.Data.trainData[i]~=nil then
                self.Data.trainData[i].NegResponse=self.Data:String2Vector(line)
                self.Data:ConstructNegativePool(self.Data.trainData[i],"NegResponse","responsePool")
                local pos_string=self.gen_yes_list[torch.random(#self.gen_yes_list)];
                self.Data.trainData[i].PosResponse
                    =self.Data:String2Vector(self.Data:process_string(pos_string))
                self.Data:ConstructNegativePool(self.Data.trainData[i],"PosResponse","responsePool")
            else break;
            end
        end
    end
end


function online_memmnet:MeMM_()
    local inputs={}
    local memory
    memory=nn.Identity()()
    table.insert(inputs,memory)
    local question=nn.Identity()()
    table.insert(inputs,question)
    local answer_v=nn.Identity()()
    table.insert(inputs,answer_v)
    local context_mask=nn.Identity()()
    local context_mask_p = nn.MulConstant(1e8)(nn.AddConstant(-1)(context_mask))
    table.insert(inputs,context_mask)
    local word_mask=nn.Identity()()
    local word_mask_p = nn.MulConstant(1e8)(nn.AddConstant(-1)(word_mask))
    table.insert(inputs,word_mask)
    local u=question;
    local store={};
    local sen_atten;
    local attens={}
    for i=1,self.params.N_hop do
        if i==1 then
            u=nn.Replicate(1,3)(u); -- add dummy dimension
        else
            u=nn.Replicate(1,3)(store[i-1]);
        end
        sen_atten=nn.MM()({memory,u});
        sen_atten=nn.Sum(3)(sen_atten);
        sen_atten = nn.CAddTable(){sen_atten, context_mask_p}
        sen_atten=nn.SoftMax()(sen_atten);
        table.insert(attens,sen_atten);
        sen_atten=nn.Replicate(1,2)(sen_atten);
        local attent_vect
        attent_vect=nn.MM()({sen_atten,memory});
        attent_vect=nn.Sum(2)(attent_vect)
        store[i]=nn.CAddTable()({attent_vect,u}):annotate{name = 'hopvec' .. i}
        --u=nn.Linear(params.dimension,params.dimension):noBias()(add_sum);
    end
    local atten;
    local expand=nn.Replicate(1,3)(store[self.params.N_hop]);
    atten=nn.MM()({answer_v,expand});
    atten=nn.Sum(3)(atten);
    atten = nn.CAddTable(){atten, word_mask_p}
    pred=nn.LogSoftMax()(atten);
    local outputs={}
    table.insert(outputs,pred)
    local pred_response;
    if self.params.FP then
        local response_v=nn.Identity()();
        table.insert(inputs,response_v)
        local beta_v=nn.Identity()();
        table.insert(inputs,beta_v)
        atten=nn.Replicate(1,2)(nn.Exp()(pred));
        local attent_vect=nn.MM()({atten,beta_v});
        attent_vect=nn.Sum(2)(attent_vect);
        local combine_v=nn.CAddTable()({attent_vect,store[self.params.N_hop]});
        combine_v=nn.Replicate(1,3)(combine_v);
        local h2rank=nn.MM()({response_v,combine_v});
        h2rank=nn.Sum(3)(h2rank);
        pred_response=nn.LogSoftMax()(h2rank);
        table.insert(outputs,pred_response)
    end
    local module=nn.gModule(inputs,outputs);
    return module:cuda();
end

function online_memmnet:LookUpTable_()
    local inputs={};
    local context
    context=nn.Identity()();
    table.insert(inputs,context)
    local question=nn.Identity()();
    table.insert(inputs,question)
    local question_table=
        self.word_table:clone('weight','bias');
    local question_v=nn.Sum(2)(question_table(question));
    local answer_table=
        self.word_table:clone('weight','bias');
    local answer=nn.Identity()();
    local answer_v=nn.Sum(2)(answer_table(answer))
    table.insert(inputs,answer)
    local context_table=
        self.word_table:clone('weight','bias');
    local context_v=nn.Sum(2)(context_table(context));
    if self.params.FP then
        local response=nn.Identity()();
        table.insert(inputs,response)
        response_table=self.word_table:clone('weight','bias');
        response_v=nn.Sum(2)(response_table(response));
        local potential_answer_beta=nn.Identity()()
        table.insert(inputs,potential_answer_beta)
        potential_answer_beta_table=self.word_table:clone('weight','bias');
        potential_answer_beta_v=nn.Sum(2)(potential_answer_beta_table(potential_answer_beta));
    end
    local module;
    local context_length
    if self.params.context then
        context_length=nn.Identity()();
        table.insert(inputs,context_length);
        answer_v=nn.CMulTable()({answer_v,context_length})
    end
    if self.params.FP then
        module=nn.gModule(inputs,{context_v,question_v,answer_v,response_v,potential_answer_beta_v});
    else module=nn.gModule(inputs,{context_v,question_v,answer_v});
    end
    return module:cuda();
end


function online_memmnet:getHopVec()
    local found = nil
    for _, node in pairs(self.MeMM.forwardnodes) do
        if node.data.annotations.name == ('hopvec'..self.params.N_hop) then
            found = node.data.module.output
        end
    end
    return found
end
function online_memmnet:PrepareNegativeResponse(Dataset)
    for i,instance in pairs(Dataset)do
        if instance.response:size(1)>self.Data.MaxResponseLength then
            self.Data.MaxResponseLength=instance.response:size(1);
        end
    end
    self.response_word=torch.Tensor(#Dataset*(1+self.params.negative),self.Data.MaxResponseLength):fill(1)
    for i,ex in pairs(Dataset)do
        local line_index=(i-1)*(1+self.params.negative)+1
        self.response_word:sub(line_index,line_index,1,ex.response:size(1)):copy(ex.response)
        for j=1,self.params.negative do
            local line_index=(i-1)*(1+self.params.negative)+1+j;
            local negative_response=self.Data.responsePool[torch.random(#self.Data.responsePool)];
            self.response_word:sub(line_index,line_index,1,negative_response:size(1)):copy(negative_response)
        end
        self.Data.responsePool[torch.random(#self.Data.responsePool)]=ex.response;
    end
    self.response_word=self.response_word:cuda()
end

function online_memmnet:prepareAnswer(Dataset)
    local max_length=-1;
    for i=1,#Dataset do
        local ex=Dataset[i]
        local length=#Dataset[i].AnswerCandidate;
        if length>max_length then
            max_length=length;
        end
    end
    self.answer_word=torch.Tensor(
        #Dataset,max_length):fill(1):cuda();
    self.answer_mask=torch.Tensor(
        #Dataset,max_length):fill(0):cuda();
    for i=1,#Dataset do
        local ex=Dataset[i]
        self.answer_word[{{i},{1,#ex.AnswerCandidate}}]
        :copy(torch.Tensor(ex.AnswerCandidate));
        self.answer_mask[{{i},{1,#ex.AnswerCandidate}}]:fill(1);
    end
    self.answer_word=torch.reshape(self.answer_word,
        self.answer_word:size(1)*self.answer_word:size(2),1);
    if self.params.FP then
        self.beta_word=torch.ones(self.answer_word:size()):cuda();
        for i=1,self.params.batch_size do
            local ex=Dataset[i];
            if ex.AnswerCandidateReverse[ex.answer[1]]~=nil then
                self.beta_word[(i-1)*max_length+
                    ex.AnswerCandidateReverse[ex.answer[1]]]=self.params.token_size;
            end
        end
        self.beta_word=torch.cat(self.answer_word,self.beta_word,2);
    end
end

function online_memmnet:PrepareContextVector(Dataset)
    self.context_length=-100
    self.context_num=-100
    for i,instance in pairs(Dataset)do
        if #instance["hist_x"]>self.context_num then
            self.context_num=#instance["hist_x"]
        end
        for j,v in pairs(instance["hist_x"])do
            if v:size(1)>self.context_length then
                self.context_length=v:size(1)
            end
        end
    end
    self.context_mask=torch.Tensor(#Dataset,self.context_num):fill(0):cuda()
    for i,instance in pairs(Dataset)do
        self.context_mask:sub(i,i,1,#instance.hist_x):fill(1);
        local context_Mat=torch.Tensor(self.context_num,self.context_length):fill(1):cuda()
        for j,v in pairs(Dataset[i].hist_x)do
            context_Mat:sub(j,j,1,v:size(1)):copy(v);
        end
        if i==1 then
            self.context_word=context_Mat;
        else
            self.context_word=torch.cat(self.context_word,context_Mat,1);
        end
    end
end

function online_memmnet:PrepareQues(Dataset)
    local max_length=-1;
    for i,instance in pairs(Dataset)do
        if instance.question:size(1)>max_length then
            max_length=instance.question:size(1)
        end
    end
    self.query_word=torch.Tensor(#Dataset,max_length):fill(1);
    for i,instance in pairs(Dataset)do
        self.query_word:sub(i,i,1,instance.question:size(1)):copy(instance.question);
    end
    self.query_word=self.query_word:cuda()
end

function online_memmnet:prepareData(Dataset)
    self:PrepareContextVector(Dataset)
    self:PrepareQues(Dataset)
    self.reward_vector=torch.Tensor(#Dataset):cuda();
    for i,instance in pairs(Dataset)do
        self.reward_vector[i]=instance.r[1]
    end
    self:prepareAnswer(Dataset)
    if self.params.FP then
        self:PrepareNegativeResponse(Dataset);
    end
end

function online_memmnet:Reshape2Dto3D(vector,n1)
    return torch.reshape(vector,
        n1,vector:size(1)/n1,
        self.params.dimension);
end


function online_memmnet:Reshape3Dto2D(vector)
    return torch.reshape(vector,
        vector:size(1)*vector:size(2),
        vector:size(3))
end

function online_memmnet:batch_train(batch_data)
    for i=1,#self.Modules do
        self.Modules[i]:zeroGradParameters()
    end
    self.n_instance=#batch_data
    self:prepareData(batch_data);
    local pred,pred_response=self:Forward()
    local d_pred=torch.Tensor(pred:size()):fill(0):cuda(); -- this stores the deriavtives to be sent back to the logsoftmax
    local d_pred_response
    local bsz = self.reward_vector:size(1)
    local baseline, baseline_input, baseline_error
    -- IM, RBI, RBI + FP
    if self.params.policyGrad or (not self.params.policyGrad and not self.params.FP) then
        --params.policyGrad: RBI or RBI+FP
        --not params.policyGrad and not params.FP: IM
        if self.params.REINFORCE then
            -- the input to the baseline module is the output
            -- of the 2nd hop.
            baseline_input = self:getHopVec()
            baseline = self.baseline:forward(baseline_input)
            baseline_error = self.mse:forward(baseline,
                                              self.reward_vector:view(bsz, 1))
        else
            baseline = torch.zeros(#batch_data):cuda()
        end
        local num_candidates=self['answer_mask']:sum(2)
        for i = 1, bsz do -- TODO: work in batch mode
            local bot_answer
            if self.params.dataset=="babi" then
                bot_answer=batch_data[i].AnswerCandidateReverse[batch_data[i].answer[1]]
            elseif self.params.dataset=="movieQA" then
                bot_answer=batch_data[i].AnswerCandidateReverse[batch_data[i].answer[1]]
            end
            -- RBI, RBI+FP
            if self.params.policyGrad then
                if bot_answer~=nil then
                    if self.params.REINFORCE then
                        -- set derivatives at output of logsoftmax
                        d_pred[i][bot_answer] =
                            baseline[i] - self.reward_vector[i]
                    else
                        -- plain epsilon-greedy RBI
                        if self.reward_vector[i] == 1 then
                            d_pred[i][bot_answer] = -1
                            self.total_cost_RBI=self.total_cost_RBI -
                                pred[i][bot_answer]
                            self.total_instance_RBI=self.total_instance_RBI + 1
                        end
                    end
                end
            else -- IM (bot_answer is always correct)
                d_pred[i][bot_answer]= -1
                self.total_cost_RBI=self.total_cost_RBI - pred[i][bot_answer]
                self.total_instance_RBI=self.total_instance_RBI + 1
            end
        end
    end
    -- FP only
    self.total_cost_FP=0
    self.total_instance_FP=0
    if self.params.FP then
        d_pred_response=torch.Tensor(pred_response:size()):fill(0):cuda();
        for i=1,self.params.batch_size do
            d_pred_response[i][1]=-1;
            self.total_cost_FP=self.total_cost_FP
                +math.exp(-pred_response[i][1]) ;
            self.total_instance_FP=self.total_instance_FP+1
        end
    end
    --print(self.total_cost_FP/self.total_instance_FP)
    -- for REINFORCE update also the baseline
    if self.params.REINFORCE then
        self.baseline:zeroGradParameters()
        self.mse:backward(baseline, self.reward_vector:view(bsz, 1))
        self.baseline:backward(baseline_input, self.mse.gradInput)
        self.baseline:updateParameters(self.params.RF_lr)
        if self.params.REINFORCE_reg > 0 then
            self.regularizer:forward(pred)
            self.regularizer:backward(
                pred, torch.CudaTensor{self.params.REINFORCE_reg})
            d_pred:add(self.regularizer.gradInput)
        end
    end
    self:Backward(d_pred,d_pred_response)
    self:update()
end


function online_memmnet:Forward()
    local vector_output;
    if self.params.FP then
        vector_output=self.LookUpTable:forward({
            self.context_word,self.query_word,self.answer_word,
            self.response_word,self.beta_word})
    else
        vector_output=self.LookUpTable:forward({
            self.context_word,self.query_word,self.answer_word})
    end
    self.context_v=vector_output[1]
    self.question_v=vector_output[2]
    self.answer_v=vector_output[3]
    self.response_v=vector_output[4]
    self.beta_v=vector_output[5]
    self.context_v=self:Reshape2Dto3D(self.context_v,self.n_instance)
    self.answer_v=self:Reshape2Dto3D(self.answer_v,self.n_instance)
    if self.params.FP then
        self.response_v=self:Reshape2Dto3D(self.response_v,self.n_instance)
        self.beta_v=self:Reshape2Dto3D(self.beta_v,self.n_instance)
    end
    local pred,pred_response;
    if self.params.FP then
        local output=self.MeMM:forward({
            self.context_v,self.question_v,self.answer_v,
            self.context_mask,self.answer_mask,
            self.response_v,self.beta_v});
        pred=output[1]
        pred_response=output[2]
    else
        local output=self.MeMM:forward({
        self.context_v,self.question_v,self.answer_v,
        self.context_mask,self.answer_mask});
        pred=output
    end
    return pred,pred_response
end

function online_memmnet:Backward(d_pred,d_pred_response)
    local grad_inputs;
    local d_context_v,d_question_v,d_answer_v
    if self.params.FP then
        grad_inputs=self.MeMM:backward({
            self.context_v,self.question_v,self.answer_v,
            self.context_mask,self.answer_mask,
            self.response_v,self.beta_v},
            {d_pred,d_pred_response})
    else
        grad_inputs=self.MeMM:backward({
            self.context_v,self.question_v,self.answer_v,
            self.context_mask,self.answer_mask},d_pred);
    end
    local d_context_v=grad_inputs[1];
    local d_question_v=grad_inputs[2];
    local d_answer_v=grad_inputs[3];
    d_context_v=self:Reshape3Dto2D(d_context_v)
    d_answer_v=self:Reshape3Dto2D(d_answer_v)
    if self.params.FP then
        local d_response_v=grad_inputs[6];
        local d_beta_v=grad_inputs[7];
        d_response_v=self:Reshape3Dto2D(d_response_v)
        d_beta_v=self:Reshape3Dto2D(d_beta_v)
        self.LookUpTable:backward({
            self.context_word,self.query_word,self.answer_word,
            self.response_word,self.beta_word},
            {d_context_v,d_question_v,d_answer_v,
            d_response_v,d_beta_v})
    else
        self.LookUpTable:backward({
            self.context_word,self.query_word,self.answer_word},
        {d_context_v,d_question_v,d_answer_v})
    end
end

function online_memmnet:test(file)
    self.total_instance_RBI=0
    local options_in_total=0;
    local batch_data_;
    if file=="dev" then
        batch_data_=self.Data.devData;
        self.model_flag="dev";
    elseif file=="test" then
        self.model_flag="test"
        batch_data_=self.Data.testData;
    end
    local right=0;
    local output_f
    for i=1,torch.floor(#batch_data_/self.params.batch_size) do
        self.total_instance_RBI=self.total_instance_RBI+self.params.batch_size
        local Begin=(i-1)*self.params.batch_size+1;
        local End=i*self.params.batch_size;
        if End>#batch_data_ then
            End=#batch_data_;
        end
        batch_data={}
        for j=Begin,End do
            batch_data[j-Begin+1]=batch_data_[j];
        end
        self.n_instance=#batch_data
        self:prepareData(batch_data)
        local pred,_=self:Forward()
        local max_p,max_index=torch.max(pred,2);
        for j=1,self.params.batch_size do
            local AnswerCandidate=batch_data[j].AnswerCandidate;
            local predict_index=max_index[j][1]
            if not (#batch_data[j].answers==1 and batch_data[j].answers[1]==1)
                and batch_data[j].answers[AnswerCandidate[predict_index]]~=nil then
                right=right+1;
            end
        end
    end
    self.model_flag="train"
    return right/self.total_instance_RBI;
end

function online_memmnet:update()
    local lr=self.current_lr;
    local grad_norm=0;
    for i=1,#self.Modules do
        local p,dp=self.Modules[i]:parameters()
        for j,m in pairs(dp) do
            grad_norm=grad_norm+m:norm()^2;
        end
    end
    grad_norm=grad_norm^0.5;
    if grad_norm>self.params.thres then
        lr=lr*self.params.thres/grad_norm;
    end
    for i=1,#self.Modules do
        self.Modules[i]:updateParameters(lr);
    end
    self.word_table.weight[1]:zero()
    for i,v in pairs(self.Modules[1].modules) do
        if v.weight~=nil then
            v.weight[1]:zero();
        end
    end
end

return online_memmnet
