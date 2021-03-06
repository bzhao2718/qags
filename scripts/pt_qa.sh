# Do QA stuff with pytorch pretrained BERT

bert_version=${2:-"bert-large-uncased"}
qst_src=${3:-"src"}
txt_fld=${4:-"trg"}
gen_mdl=${5:-"fseq"}
date=$(date '+%m-%d-%Y')

function train_squad_v1_1() {
	export SQUAD_DIR=~/data/squad/v1.1/original
	export OUT_DIR=/checkpoint/wangalexc/ppb/${bert_version}/squad_v1_1/${date}
    mkdir -p ${OUT_DIR}

	python finetune_pt_squad.py \
	  --bert_model ${bert_version}  \
      --do_train \
	  --do_predict \
	  --do_lower_case \
	  --train_file $SQUAD_DIR/train-v1.1.json \
	  --predict_file $SQUAD_DIR/dev-v1.1.json \
	  --train_batch_size 24 \
	  --learning_rate 3e-5 \
	  --num_train_epochs 2.0 \
	  --max_seq_length 384 \
	  --doc_stride 128 \
	  --output_dir ${OUT_DIR} \
      --overwrite_output_dir
}

function train_squad_v2_0() {
	export SQUAD_DIR=~/data/squad/v2.0/original
	export OUT_DIR=/checkpoint/wangalexc/ppb/${bert_version}/squad_v2_0/${date}
    mkdir -p ${OUT_DIR}

	python finetune_pt_squad.py \
	  --bert_model ${bert_version} \
      --do_train \
	  --do_predict \
	  --do_lower_case \
	  --train_file $SQUAD_DIR/train.json \
	  --predict_file $SQUAD_DIR/dev.json \
      --version_2_with_negative \
	  --train_batch_size 24 \
	  --learning_rate 3e-5 \
	  --num_train_epochs 2.0 \
	  --max_seq_length 384 \
	  --doc_stride 128 \
	  --output_dir ${OUT_DIR} \
      --overwrite_output_dir
}

function train_nlg() {
    model="gpt2-medium"
	data_dir="/private/home/wangalexc/data/squad/v2.0/original"
	out_dir="/checkpoint/wangalexc/ppb/${model}/squadv2_0_freetext/${date}"
	tmp_dir="/checkpoint/wangalexc/ppb/${model}/squadv2_0_freetext/07-25-2019"
    mkdir -p ${out_dir}

    task="squad-qa-freetext"
    batch_size=4
    grad_accum=1
    learning_rate=.001
    n_epochs=1
    patience=1
    opt_level="O3"
    use_distributed=0
    world_size=8

    if [ ${use_distributed} -eq 1 ]; then
        python -m torch.distributed.launch --nproc_per_node=${world_size} finetune_pt_lm.py \
            --model_name ${model} \
            --task_name ${task} \
            --data_dir ${data_dir} \
            --out_dir ${out_dir} \
            --no_input_lm_eval \
            --train_batch_size ${batch_size} \
            --gradient_accumulation_steps ${grad_accum} \
            --learning_rate ${learning_rate} \
            --num_train_epochs ${n_epochs} \
            --patience ${patience} \
            --fp16 --fp16_opt_level ${opt_level} \
            --world_size ${world_size}
            #--reload_data
            #--no_input_lm_train \
    else
        python -m ipdb finetune_pt_lm.py \
            --model_name ${model} \
            --task_name ${task} \
            --data_dir ${data_dir} \
            --out_dir ${out_dir} \
            --no_input_lm_eval \
            --train_batch_size ${batch_size} \
            --gradient_accumulation_steps ${grad_accum} \
            --learning_rate ${learning_rate} \
            --num_train_epochs ${n_epochs} \
            --patience ${patience} \
            --fp16 --fp16_opt_level ${opt_level} \
            --use_only_gpuid 0 \
            --skip_training #\
            #--load_model_from ${tmp_dir} #\
            #--no_input_lm_train \
            #--reload_data
    fi

}

function evaluate_v1_1() {
	export data_file="/private/home/wangalexc/data/squad/v1.1/original/dev-v1.1.json"

	# bert base uncased
 	#export pred_file="/checkpoint/wangalexc/ppb/bert-base-uncased/squad_v1_1/06-25-2019/predictions.json"

	# bert large uncased
	export pred_file="/checkpoint/wangalexc/ppb/bert-large-uncased/squad_v1_1/06-25-2019/predictions.json"

	python evaluate-squad-v1-1.py ${data_file} ${pred_file}
}

function evaluate_v2_0() {

    bert_version="bert-large-uncased-whole-word-masking"
    date="06-25-2019"
    squad_version="v2_0"
    ckpt_dir="/misc/vlgscratch4/BowmanGroup/awang/ckpts"
    ckpt_dir="${ckpt_dir}/ppb/${bert_version}/squad_${squad_version}/${date}-${squad_version}"
	data_file="/misc/vlgscratch4/BowmanGroup/awang/processed_data/squad/v2.0/original/dev.json"
    out_dir="${ckpt_dir}/squad${squad_version}/dev"
	out_file="${out_dir}/predictions.json"
    gpu_id=2
    batch_size=32
    
    mkdir -p ${out_dir}

    # make predictions
    python finetune_pt_squad.py \
      --local_rank ${gpu_id} \
      --bert_model ${bert_version} \
      --do_predict \
      --do_lower_case \
      --predict_file ${data_file} \
      --predict_batch_size ${batch_size} \
      --max_seq_length 384 \
      --doc_stride 128 \
      --output_dir ${out_dir} \
      --prediction_file ${out_file} \
      --overwrite_output_dir \
      --load_model_from_dir ${ckpt_dir} \
      --version_2_with_negative;

    # evaluate predictions
	python evaluate-squad-v2-0.py --data-file ${data_file} --pred-file ${out_file}

}

function predict_extractive() {

    ckpt_dir="/misc/vlgscratch4/BowmanGroup/awang/ckpts"
    date="06-25-2019"
    squad_version="v2_0"
    bert_version="bert-large-uncased"
    ckpt_dir="${ckpt_dir}/ppb/${bert_version}/squad_${squad_version}/${date}-${squad_version}"
    n_ans=10
    n_qsts=20
    dataset="wikinews"
    dec_method="nhyps10.beam10.diverse10"
    subset="120519-${n_ans}ans-${dec_method}"
    #subset="random150-${n_ans}ans-${dec_method}"
    #subset="random1000-${n_ans}ans"
    tmp="${dataset}-${subset}"
    qg_model="qg-newsqa-ans"
    use_all=0
    use_exp_ans=0
    use_act_ans=1
    use_hack=0
    beam=10
    diverse=0
    topk=0
    topp=0
    gpu_id=4
    batch_size=64

    # type of question filtering applied
    if [ ${use_all} -eq 1 ]; then
        qst_prefix="qstall"
        echo "Predicting for all questions!"
    else
        if [ ${use_exp_ans} -eq 1 ]; then
            qst_prefix="qst_w_match${n_qsts}${bert_version}"
        elif [ ${use_act_ans} -eq 1 ]; then
            qst_prefix="qst_w_ans${n_qsts}${bert_version}"
        else
            qst_prefix="qst${n_qsts}"
        fi
        qst_prefix="${qst_prefix}"
    fi

    # decoding type
    if [ ${topk} -gt 0 ]; then
        dec_opt="topk${topk}"
    elif [ ${diverse} -gt 0 ]; then
        dec_opt="beam${beam}.diverse${diverse}"
    elif [ ${beam} -gt 0 ]; then
        dec_opt="beam${beam}"
    else
        dec_opt="topp${topp}"
    fi
    if [ ${use_hack} -gt 0 ]; then
        dec_opt="${dec_opt}w_hack"
    fi

    # what text fields to iterate over
    if [[ ${use_all} -eq 1 ]]; then
        iter=("gen")
    elif [[ ${dataset} = "xsum" ]]; then
        iter=("src_w_trg" "gen")
    elif [[ ${dataset} = "wikinews" ]]; then
        iter=("src_w_trg" "gen")
    else
        iter=("src" "gen")
    fi

    for txt_fld in ${iter[@]}; do
        for qst_src in gen; do
            out_dir="${ckpt_dir}/${tmp}/bart"
            mkdir -p ${out_dir}

            pred_file="/home/awang/projects/qags/data/${dataset}/${subset}/${qst_prefix}-${qst_src}-${qg_model}-${dec_opt}.${tmp}-${txt_fld}.json"
            out_file="${out_dir}/prd.${qst_prefix}-${qst_src}-${qg_model}-${dec_opt}.${tmp}-${txt_fld}.json"

            python finetune_pt_squad.py \
              --local_rank ${gpu_id} \
              --predict_batch_size ${batch_size} \
              --bert_model ${bert_version} \
              --do_predict \
              --do_lower_case \
              --predict_file ${pred_file} \
              --max_seq_length 384 \
              --doc_stride 128 \
              --output_dir ${out_dir} \
              --prediction_file ${out_file} \
              --overwrite_output_dir \
              --load_model_from_dir ${ckpt_dir} \
              --version_2_with_negative;

        done;
    done;

}

function evaluate_answers() {
    squad_version="2_0"
    n_qst=6
    qg_ckpt="best"
    #gen_mdl="pgc-subset500"
    dataset="xsum-random1000"
    gen_mdl="bart"
    qst_src="gen"
    txt_fld="gen"

    #src_file=/checkpoint/wangalexc/ppb/${bert_version}/squad_v${squad_version}/06-25-2019-v${squad_version}/${gen_mdl}/prd.qst${n_qst}-ckpt${qg_ckpt}-${qst_src}.cnndm-src.json
    #trg_file=/checkpoint/wangalexc/ppb/${bert_version}/squad_v${squad_version}/06-25-2019-v${squad_version}/${gen_mdl}/prd.qst${n_qst}-ckpt${qg_ckpt}-${qst_src}.cnndm-${txt_fld}.json
    #out_dir=/checkpoint/wangalexc/ppb/${bert_version}/squad_v${squad_version}/06-25-2019-v${squad_version}/${gen_mdl}/
    out_dir=/checkpoint/wangalexc/ppb/${bert_version}/squad_v${squad_version}/06-25-2019-v${squad_version}/${dataset}/${gen_mdl}
    src_file=${out_dir}/xsum-prd.qst${n_qst}-${qst_src}.cnndm-src.json
    trg_file=${out_dir}/xsum-prd.qst${n_qst}-${qst_src}.cnndm-${txt_fld}.json
    #corr_file=/private/home/wangalexc/projects/qags/data/labeled-subset/${gen_mdl}.scores.txt
    corr_file=/private/home/wangalexc/projects/qags/data/labeled-subset/qags-subset-human-eval-means.csv

    echo "Gold file: ${src_file}"
    echo "Pred file: ${trg_file}"
    python eval_ppb_answers.py --source-ans-file ${src_file} --target-ans-file ${trg_file} --outdir ${out_dir} --correctness-file ${corr_file} --n-qsts-per-doc 5 #${n_qst}
    #python -m ipdb evaluate-squad-v2-0.py --data-file ${src_file} --pred-file ${trg_file} --verbose

}

function evaluate_all_answers() {
    squad_version="2_0"
    gen_mdl="lstm"

    for qst_src in src gen trg; do 
        for txt_fld in trg gen; do
            for bert_version in bert-base-uncased bert-large-uncased bert-large-uncased-whole-word-masking; do
                src_file=/checkpoint/wangalexc/ppb/${bert_version}/squad_v${squad_version}/06-25-2019-v${squad_version}/${gen_mdl}/prd.qst-${qst_src}.cnndm-src.json
                trg_file=/checkpoint/wangalexc/ppb/${bert_version}/squad_v${squad_version}/06-25-2019-v${squad_version}/${gen_mdl}/prd.qst-${qst_src}.cnndm-${txt_fld}.json

                echo "Gold file: ${src_file}"
                echo "Pred file: ${trg_file}"
                python eval_ppb_answers.py --source-ans-file ${src_file} --target-ans-file ${trg_file};
                #python -m ipdb evaluate-squad-v2-0.py --data-file ${src_file} --pred-file ${trg_file} --verbose
            done;
        done;
    done
}

if [ $1 == "train-squadv1.1" ]; then
    train_squad_v1_1
elif [ $1 == "train-squadv2.0" ]; then
    train_squad_v2_0
elif [ $1 == "train-nlg" ]; then
    train_nlg
elif [ $1 == "evaluate-v1.1" ]; then
    evaluate_v1_1
elif [ $1 == "evaluate-v2.0" ]; then
    evaluate_v2_0
elif [ $1 == "predict-extractive" ]; then
    predict_extractive
elif [ $1 == "evaluate" ]; then
    evaluate_answers
elif [ $1 == "evaluate-all" ]; then
    evaluate_all_answers
else
    echo "Command not found"
fi
