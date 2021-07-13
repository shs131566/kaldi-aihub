#-*- coding: utf-8 -*-
# 
# Copyright 2020     Hyunsoo Son
#              
# 
# This file removes special symbols contained in aihub korean speech data.
# Special symbols are defined at [한국어 음성 전사 규칙 v1.0.pdf].

import re
import sys
import argparse

parser = argparse.ArgumentParser(description="This file removes special symbol contained in aihub data")
parser.add_argument('--option', '--o', type=str, choices=['KR', 'NUM'], default='KR')
args = parser.parse_args()

for line in sys.stdin: 
    if args.option == 'KR':    
        line = re.sub('\((.+?)\)/\((.+?)\)', '\\2', line)
    elif args.option == 'NUM':
        line = re.sub('\((.+?)\)/\((.+?)\)', '\\1', line)
        
    line = re.sub('b/|l/|o/|n/|\+|\?|\.|,|\*|\!', '', line)
    line = re.sub('/', '', line)
    line = re.sub('u', '', line)
    line = re.sub('\s+', ' ', line)
    line = re.sub('^\s', '', line)
    print(line)

