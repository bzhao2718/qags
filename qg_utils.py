"""  """

import os
import re
import ast
import time
import json
import copy
import random
import argparse
import itertools
from tqdm import tqdm
from datetime import datetime
from functools import lru_cache
from collections import defaultdict, Counter

import numpy as np
import pandas as pd
import spacy
from nltk.tokenize import sent_tokenize
from nltk import agreement
try:
    from nlgeval import compute_metrics, NLGEval
except ModuleNotFoundError as e:
    print("Unable to import NLGEval library!")
try:
    from bert_score import score as bert_score
except ModuleNotFoundError as e:
    print("Unable to import BERT Score!")
try:
    import krippendorff
except ModuleNotFoundError as e:
    print("Unable to import Krippendorff!")
from scipy.stats import pearsonr, spearmanr
import rouge

from utils import write_data, write_jsonl, write_txt, \
                  process, print_samples, format_squad, \
                  filter_line_fseq, parse_generation, \
                  load_txt, load_json
from eval_ppb_answers import evaluate, load_data, align_ans, count_noans


ANS_TOK = "[ANS]"
NO_ANS_TOK = "[NO_ANS]"


def extract_ans(txts):
    """ extract entities from a sentence using spacy

    rules:
        - entities (non-pronoun)
            - each portion of a person's name
        - noun chunks (non-pronoun)
            - adjectives within noun chunks
            - nouns w/ dependencies that are proper nouns, roughly nouns modifying proper nouns
            - if the head of a noun chunk if a verb, the entire noun chunk ?
        - for each conjunction,
            - the subtree of the head
            - the subtree of the children
    """
    nlp = get_spacy_nlp("en_core_web_lg")
    all_ans = list()
    for doc in nlp.pipe(txts, disable=[]):
        ans = list()
        for ent in doc.ents:
            ans.append(ent.text)
            #if not (len(ent) == 1 and ent[0].pos_ in ['PRON']):
            #    ans.append(ent.text)
            #if ent.label_ in ['PERSON']:
            #    for tok in ent:
            #        ans.append(tok.text)
        for chunk in doc.noun_chunks:
            ans.append(chunk.text)
            #if not (len(chunk) == 2 and chunk[0].pos_ in ['PRON']):
            #    ans.append(chunk.text)
            #for tok in chunk:
            #    if tok.pos_ in ['ADJ']:
            #        ans.append(tok.text)

            #    if tok.pos_ in ['NOUN'] and tok.head.pos_ in ['PROPN']:
            #        ans.append(tok.text)

            #    if tok.head.pos_ in ['VERB']:
            #        ans.append(' '.join([t.text for t in tok.head.subtree]))

        #specials = [t for t in doc if t.pos_ in ['SCONJ'] or t.tag_ in ['IN']]
        #for special in specials:
        #    ans.append(' '.join([t.text for t in special.head.subtree]))
        #    # subtrees of conjunctions
        #    for child in special.children:
        #        if child.is_punct or child.is_quote:
        #            continue
        #        ans.append(' '.join([t.text for t in child.subtree]))

        ans = list(set(ans))
        #ans = sorted(ans, key=lambda x: len(x))
        #ipdb.set_trace()
        all_ans.append(ans)
    return all_ans


def prepare_ans_conditional_data(data_file,
                                 out_dir,
                                 out_prefix,
                                 n_ans_per_txt=10,
                                 use_no_ans=False,
                                 use_only_no_ans=False,
                                 ):
    """ Given a text file, extract possible answer candidates for each line.

    Will generate CONST instances for each line in txt

    For posteriority, old paths:
    txt_fld = "bart"

    # Falke
    split = "correct"
    data_file = f"{DATA_DIR}/falke-correctness/sent_reranking/test.{split}.txt"
    out_dir = f"{DATA_DIR}/falke-correctness/sent_reranking/{split}2src-{n_ans_per_txt}ans"
    txt_w_ans_file = f"{out_dir}/test.{split}_w_ans.txt"
    txt_file = f"{out_dir}/test.{split}.txt"
    ans_file = f"{out_dir}/test.{split}_ans.txt"

    # XSUM
    data_file = f"{DATA_DIR}/xsum/random1000/xsum.test.{txt_fld}.10251125.random1000.txt"
    out_dir = f"{DATA_DIR}/xsum/random1000-{n_ans_per_txt}ans"
    txt_w_ans_file = f"{out_dir}/xsum.test.{txt_fld}_w_{n_ans_per_txt}ans.random1000.txt"
    txt_file = f"{out_dir}/xsum.test.{txt_fld}.txt"
    ans_file = f"{out_dir}/xsum.test.{txt_fld}_{n_ans_per_txt}ans.random1000.txt"

    # CNN/DM
    data_file = f"{DATA_DIR}/cnndailymail/fseq/subset1000/subset1000.{txt_fld}.random.ref_order.txt"
    out_dir = f"{DATA_DIR}/cnndailymail/fseq/random1000-{n_ans_per_txt}ans"
    txt_w_ans_file = f"{out_dir}/cnndm.test.{txt_fld}_w_{n_ans_per_txt}ans.random1000.txt"
    txt_file = f"{out_dir}/cnndm.test.{txt_fld}.random1000.txt"
    ans_file = f"{out_dir}/cnndm.test.{txt_fld}_{n_ans_per_txt}ans.random1000.txt"
    """

    txt_w_ans_file = f"{out_dir}/{out_prefix}_w_{n_ans_per_txt}ans.txt"
    txt_file = f"{out_dir}/{out_prefix}.txt"
    ans_file = f"{out_dir}/{out_prefix}_{n_ans_per_txt}ans.txt"

    print(f"Preparing answer conditional question generation data for {data_file}")
    if use_only_no_ans:
        print("\twith ONLY NO_ANS!")
    elif use_no_ans:
        print("\twith NO_ANS option!")
    else:
        print("\twithout NO_ANS option!")

    all_txts = load_txt(data_file)
    print("Extracting entities...")
    all_anss = extract_ans(all_txts)
    print("\tDone!")
    print(f"\tMin ans count: {min(len(a) for a in all_anss)}")
    print(f"\tMax ans count: {max(len(a) for a in all_anss)}")

    print("Writing...")
    txts_w_ans = list()
    all_txt = list()
    all_ans = list()
    for txt, anss in zip(all_txts, all_anss):
        if use_only_no_ans:
            anss = [NO_ANS_TOK] * n_ans_per_txt
        elif use_no_ans:
            if len(anss) > n_ans_per_txt - 1:
                anss = random.sample(anss, k=n_ans_per_txt - 1)
            anss += [NO_ANS_TOK] * (n_ans_per_txt - len(anss))
            assert NO_ANS_TOK in anss, ipdb.set_trace()
        else:
            if len(anss) < n_ans_per_txt:
                extra_anss = random.choices(anss, k=n_ans_per_txt - len(anss))
                anss += extra_anss
            if len(anss) > n_ans_per_txt:
                anss = random.sample(anss, n_ans_per_txt)
            assert len(anss) == n_ans_per_txt, ipdb.set_trace()

        for ans in anss:
            txts_w_ans.append(f"{txt} {ANS_TOK} {ans}")
            all_txt.append(txt)
            all_ans.append(ans)

    if not os.path.exists(out_dir):
        os.makedirs(out_dir)
    with open(txt_w_ans_file, 'w') as out_fh:
        for txt in txts_w_ans:
            out_fh.write(f'{txt}\n')
    with open(txt_file, 'w') as out_fh:
        for txt in all_txt:
            out_fh.write(f'{txt}\n')
    with open(ans_file, 'w') as out_fh:
        for ans in all_ans:
            out_fh.write(f'{ans}\n')
    print("\tDone!")
    print(f"\tWrote {len(txts_w_ans)} sentences to {txt_w_ans_file}")


def main(arguments):
    parser = argparse.ArgumentParser(description="")
    parser.add_argument("--command", choices=["extract_ans", "filter_qsts"], description="Function to perform")
    parser.add_argument("--data_file", type=str, description="File from which to extract answers or filter questions. For `extract_ans`, this should be a text file with an example per line.")
    parser.add_argument("--out_dir", type=str, description="Directory to write outputs")
    parser.add_argument("--out_prefix", type=str, description="Prefix for files written out")

    # answer extraction options
    parser.add_argument("--n_ans", type=int, default=10, description="Number of answer candidates per example")

    args = parser.parse_args(arguments)

    if args.command == "extract_ans":
        prepare_ans_conditional_data(args.data_file, args.out_dir, args.out_prefix,
                                     n_ans_per_txt=args.n_ans)
    elif args.command == "filter_qsts":
        filter_qsts()

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))