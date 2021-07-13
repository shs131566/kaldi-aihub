#!/bin/bash

data=$1

stage=0
nj=`grep -c processor /proc/cpuinfo`

vocab_size=3000

exp=exp
train=train
test=test
lang_nosp=lang_nosp
lang=lang
lm=lm
subword=subowrd
dict_nosp=dict_nosp
dict=dict
mfcc=mfcc

set -e

. ./cmd.sh
. ./path.sh
. parse_options.sh


if [ $stage -le 0 ]; then
    echo -e "[Stage 0]: Data prep for aihub."
   
    if [ ! -d data/local/$subword ]; then
        mkdir -p data/local/$subword
    fi

    if [ ! -d data/$train ]; then
        mkdir -p data/$train
    fi

    if [ ! -d data/$test ]; then
        mkdir -p data/$test/test_clean
        mkdir -p data/$test/test_other
    fi
    
    python3 local/data_prep.py $1
    for trn in "train.trn" "eval_clean.trn" "eval_other.trn"
    do
        cat $1/KsponSpeech_scripts/$trn | awk -F " :: " '{ print $2 }' \
            | python3 local/text_preprocessing.py | sed '/[^ 가-힣]/d' >  data/local/$subword/${trn:0:-4}.txt
    done
    
    for dir in "data/train" "data/test/test_clean" "data/test/test_other"
    do
        cut -d " " -f1 $dir/text > tmp ; f=$(cut -d " " -f 1 $dir/text) ; awk '{print $f" "$0}' tmp > \
            $dir/spk2utt ; cp $dir/spk2utt $dir/utt2spk ; rm tmp
        utils/validate_data_dir.sh --no-feats $dir
    done            
fi

if [ $stage -le 1 ]; then
    echo -e "[Stage 1]: Training subword tokenizer."

    spm_train --input data/local/$subword/train.txt --model_prefix=data/local/$subword/subword \
        --model_type=bpe --hard_vocab_limit=false --vocab_size=$vocab_size --character_coverage=1.0 
fi

if [ $stage -le 2 ]; then
    echo -e "[Stage 2]: Tokenize text corpus."

    if [ ! -d data/local/$lm ]; then
        mkdir -p data/local/$lm
    fi

    spm_encode --model data/local/$subword/subword.model \
        --output data/local/$lm/train.txt < data/local/$subword/train.txt
fi

if [ $stage -le 3 ]; then
    echo -e "[Stage 3]: Training language model."

    norder=3
    prune_prob=1e-8
     
    # Make subword vocab 
    cut -f1 data/local/$subword/subword.vocab | sed '/^_/d' > data/local/$lm/vocab

    # Train N-gram language model.
    ngram-count -vocab data/local/$lm/vocab -text data/local/$lm/train.txt -order $norder \
        -lm data/local/$lm/lm.arpa -prune $prune_prob -wbdiscount 1 -wbdiscount 2 -wbdiscount 3 -debug 2

    # Create lexicon by G2P.
    sed -n '4, $ p' data/local/$lm/vocab | python local/g2p/g2p.py | sed '/^▁ /d' > data/local/$lm/lexicon_nosil.txt
fi

if [ $stage -le 4 ]; then
    echo -e "[Stage 4]: Format the data as Kaldi data directories."
    
    # Make dict & lang
    local/prepare_dict.sh data/local/$lm data/local/$dict_nosp
    utils/prepare_lang.sh data/local/$dict_nosp "<UNK>" data/local/$lang_nosp data/$lang_nosp

    # Make G.fst
    cat data/local/$lm/lm.arpa | arpa2fst --disambig-symbol=#0 \
        --read-symbol-table=data/$lang_nosp/words.txt - data/$lang_nosp/G.fst
    utils/validate_lang.pl --skip-determinization-check data/$lang_nosp
fi

if [ $stage -le 5 ]; then
    echo -e "[Stage 5]: Create feature from the data."

    steps/make_mfcc.sh --cmd "$train_cmd" --nj $nj data/$train exp/make_mfcc/$train $mfcc/$train
    steps/compute_cmvn_stats.sh data/$train exp/make_mfcc/$train $mfcc/$train

    for dir in "test_clean" "test_other"; do
        steps/make_mfcc.sh --cmd "$train_cmd" --nj $nj data/$test/$dir exp/make_mfcc/$test/$dir
        steps/compute_cmvn_stats.sh data/$test/$dir exp/make_mfcc/$test/$dir $mfcc/$test/$dir
    done
fi

if [ $stage -le 6 ]; then
    echo -e "[Stage 6]: Train mono phone & Align mono"

    utils/subset_data_dir.sh --shortest data/$train 2000 data/${train}_2Kshort
    steps/train_mono.sh --boost-silence 1.25 --nj $nj --cmd "$train_cmd" data/${train}_2Kshort data/$lang_nosp exp/mono
    steps/align_si.sh --boost-silence 1.25 --nj $nj --cmd "$train_cmd" data/$train data/$lang_nosp exp/mono exp/mono_ali
fi

if [ $stage -le 7 ]; then
    echo -e "[Stage 7]: Train tri1 & Align tri1"

    utils/subset_data_dir.sh data/$train 5000 data/train_5K
    steps/train_deltas.sh --boost-silence 1.25 --cmd "$train_cmd" 2000 10000 data/${train}_5K data/$lang_nosp exp/mono_ali exp/tri1
    steps/align_si.sh --nj $nj --cmd "$train_cmd" data/$train data/$lang_nosp exp/tri1 exp/tri1_ali
fi

if [ $stage -le 8 ]; then
    echo -e "[Stage 8]: Train tri2b & Align tri2b"

    utils/subset_data_dir.sh data/$train 10000 data/${train}_10K
    steps/train_lda_mllt.sh --cmd "$train_cmd" --splice-opts "--left-context=3 --right-context=3" 2500 15000 \
        data/${train}_10K data/$lang_nosp exp/tri1_ali exp/tri2b
    steps/align_si.sh --nj $nj --cmd "$train_cmd" data/$train data/$lang_nosp exp/tri2b exp/tri2b_ali
fi

if [ $stage -le 9 ]; then
    echo -e "[Stage 9]: Train tri3b & Align tri3b"

    steps/train_sat.sh --cmd "$train_cmd" 2500 15000 data/${train}_10K data/$lang_nosp exp/tri2b_ali exp/tri3b
    steps/align_fmllr.sh --nj $nj --cmd "$train_cmd" data/$train data/$lang_nosp exp/tri3b exp/tri3b_ali
fi

if [ $stage -le 10 ]; then
    echo -e "[Stage 10]: Train tri4b & Align tri4b"

    steps/train_sat.sh --cmd "$train_cmd" 4200 40000 data/$train data/$lang_nosp exp/tri3b_ali exp/tri4b
    steps/get_prons.sh --cmd "$train_cmd" data/$train data/$lang_nosp exp/tri4b
    utils/dict_dir_add_pronprobs.sh --max-normalize true data/local/$dict_nosp exp/tri4b/pron_counts_nowb.txt \
        exp/tri4b/sil_counts_nowb.txt exp/tri4b/pron_bigram_counts_nowb.txt data/local/$dict
    utils/prepare_lang.sh data/local/$dict "<UNK>" data/local/$lang_nosp data/$lang
    cat data/local/$lm/lm.arpa | arpa2fst --disambig-symbol=#0 --read-symbol-table=data/$lang/words.txt - data/$lang/G.fst
    utils/validate_lang.pl --skip-determinization-check data/$lang
    
    steps/align_fmllr.sh --nj $nj --cmd "$train_cmd" data/$train data/$lang exp/tri4b exp/tri4b_ali
fi

if [ $stage -le 11 ]; then
    echo -e "[Stage 11]: Decode using tri4b model."

    utils/mkgraph.sh data/$lang exp/tri4b exp/tri4b/graph

    for part in "test_clean" "test_other" 
    do
        steps/decode_fmllr.sh --nj $nj --cmd "$decode_cmd" exp/tri4b/graph data/$test/$part exp/tri4b/decode_$part
        steps/scoring/score_kaldi_cer.sh data/$test/$part data/$lang exp/tri4b/decode_$part.si
    done
fi

if [ $stage -le 12 ]; then
    echo -e "[Stage 12]: Preparing speed-perturbation."

    utils/fix_data_dir.sh data/$train
    utils/data/perturb_data_dir_speed_3way.sh data/$train data/${train}_sp_hires
fi

if [ $stage -le 13 ]; then
    echo -e "[Stage 13]: Make MFCC for speed-perturbation data."

    steps/make_mfcc.sh --cmd "$train_cmd" --nj $nj --mfcc_config conf/mfcc_hires.conf \
        data/${train}_sp_hires
    steps/compute_cmvn_stats.sh data/${train}_sp_hires

    utils/fix_data_dir.sh data/${train}_sp_hires
fi

if [ $stage -le 14 ]; then
    echo -e "[Stage 14]: Align speed-perturbation data."

    steps/align_fmllr.sh --cmd "$train_cmd" --nj $nj data/train_sp data/lang exp/tri4b exp/tri4b_sp_ali
fi

if [ $stage -le 15 ]; then
    echo -e "[Stage 15]: TDNN train."

    local/nnet3/run_tdnn.sh
fi
