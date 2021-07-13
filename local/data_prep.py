# -*- coding: utf-8 -*-

"""
    @file   data_prep.py
    @date   2021.06.30
    @author Hyunsoo Son
    @brief  Data preparation for AIHUB
"""

import sys
import re

train = sys.argv[1] + 'KsponSpeech_scripts/train.trn'
eval_clean = sys.argv[1] + 'KsponSpeech_scripts/eval_clean.trn'
eval_other = sys.argv[1] + 'KsponSpeech_scripts/eval_other.trn'

train_dir = 'data/train'
eval_clean_dir = 'data/test/test_clean'
eval_other_dir = 'data/test/test_other'

train_dict = {}
eval_clean_dict = {}
eval_other_dict = {}

# Make wav.scp and text file
def data_prep(trn: str, path: str, d: dict):
    with open(trn, 'r', encoding='utf-8') as f, \
        open(path + '/wav.scp', 'w', encoding='utf-8') as wav, \
        open(path + '/text', 'w', encoding='utf-8') as text:    
        lines = f.readlines()
    
        for line in lines:
            key, value = line.strip('\n').split(' :: ')
            
            # AIHUB 한국어 음성 전사규칙 v1.0에 따른 전처리
            # 영어가 포함된 문장은 학습에 사용하지 않음
            value = re.sub('\((.+?)\)/\((.+?)\)', '\\2', value)
            value = re.sub('b/|l/|o/|n/|\+|\?|\.|,|\*|\!', '', value)
            value = re.sub('/|u', '', value)
            value = re.sub('\s+', ' ', value)
            value = re.sub('^\s', '', value)
            
            # PCM to wav header
            if (re.match('[^ 가-힣]', value) == None):
                d[key.split('/')[-1][:-4]] = ('sox -t raw -r 16000 -e signed -b 16 -c 1 ' + \
                sys.argv[1] + '/' + key + ' -t wav - |', value)

    
        for key in sorted(list(d.keys())):
            wav.write(key + ' ' +  d[key][0] + '\n')
            text.write(key + ' ' + d[key][1] + '\n')

print("preparation for train set")
data_prep(train, train_dir, train_dict)

print("preparation for eval_clean")
data_prep(eval_clean, eval_clean_dir, eval_clean_dict)

print("preparation for eval_other")
data_prep(eval_other, eval_other_dir, eval_other_dict)
