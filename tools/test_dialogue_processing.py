import asyncio
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import pymupdf as fitz

from tools.dialogue_processing import (
    detect_speaker_and_voice, detect_scene_markers, dialogue_priority,
    sort_sentences_by_dialogue_logic, prepare_page_dialogue, load_reviewed_context,
)
from tools.build_textbook_assets import parser, synthesize, configure_sentence_voice, speech_fingerprint

ROOT = Path(__file__).resolve().parents[1]


def entry(text, y, x=.2):
    return {'id': text, 'text': text, 'rect': {'left': x, 'top': y, 'right': x+.1, 'bottom': y+.02}}


class DialogueTests(unittest.TestCase):
    def setUp(self):
        configuration = patch.multiple('tools.build_textbook_assets', VOLC_API_KEY='test-key',
            VOLC_APPID='', VOLC_TOKEN='', VOLC_RESOURCE_ID='seed-tts-2.0', VOICE_MAP={
                role: 'test-' + role for role in ('girl', 'boy', 'dino',
                'teacher_female', 'teacher_male', 'narrator')})
        configuration.start()
        self.addCleanup(configuration.stop)

    def test_fixed_role_categories(self):
        for speaker, role in [('Lingling', 'girl'), ('Lulu', 'girl'),
                               ('Peter', 'boy'), ('Tim', 'boy'),
                               ('Miss Li', 'teacher_female'), ('Mr Yang', 'teacher_male'),
                               ('Dino', 'dino')]:
            result = detect_speaker_and_voice("Hello!", {'speaker': speaker})
            self.assertEqual(result['voiceRole'], role)

    def test_recipient_is_not_speaker_and_context_takes_precedence(self):
        self.assertEqual(detect_speaker_and_voice('Hello, Peter!')['speaker'], 'Narrator')
        self.assertEqual(detect_speaker_and_voice("Hello, Tim. I'm Dino Dinosaur.")['speaker'], 'Dino')
        self.assertEqual(detect_speaker_and_voice('Dino, how old are you?', {'participants': ['Tim','Dino']})['speaker'], 'Tim')
        self.assertEqual(detect_speaker_and_voice("He's my brother, Dongdong.")['speaker'], 'Narrator')
        self.assertEqual(detect_speaker_and_voice('Hello, Peter!', {'speaker':'Miss Li'})['speaker'], 'Miss Li')
        self.assertEqual(detect_speaker_and_voice("My name is Peter.", {'allow_text_inference':False})['speaker'], 'Narrator')

    def test_priority_and_stable_vertical_ties(self):
        for text in ['Hello!', 'Hi.', 'Good morning.', "What's your name?", 'What is this?',
                     'How old are you?', "Who's he?", 'Is this your pen?', 'Stand up, please.',
                     'Follow me!', 'Raise your hand.', 'Dino, how old are you?']:
            self.assertEqual(dialogue_priority(text), 1, text)
        for text in ['Hello, Peter.', 'Good morning, Miss Li.', "I'm nine.", 'Yes, it is.']:
            self.assertEqual(dialogue_priority(text), 2, text)
        for text in ['Thank you.', "You're welcome.", 'Goodbye!', 'Bye.', 'See you.']:
            self.assertEqual(dialogue_priority(text), 3, text)
        source = [entry('Thank you.',.1),entry("I'm nine.",.2),entry('How old are you?',.3)]
        self.assertEqual([s['text'] for s in sort_sentences_by_dialogue_logic(source)],
                         ['How old are you?', "I'm nine.", 'Thank you.'])
        ties = [entry("I'm Tim.",.4),entry("I'm Dino.",.2)]
        self.assertEqual(sort_sentences_by_dialogue_logic(ties)[0]['text'], "I'm Dino.")

    def test_cache_identity_uses_configured_voice_and_speed(self):
        profile=detect_speaker_and_voice('Hello', {'speaker':'Dino'})
        source={'text':'Hello',**profile}
        configure_sentence_voice(source)
        original=speech_fingerprint(source)
        for key,value in [('text','Hi'),('voice','test-boy'),('speedRatio',0.8)]:
            self.assertNotEqual(original,speech_fingerprint({**source,key:value}))

    def test_real_comic_order_and_page_music_numbers(self):
        pdf=ROOT/'assets/textbook.pdf'
        reviewed=load_reviewed_context(pdf,'xiangshao_3_1')
        book=json.loads((ROOT/'assets/textbooks/xiangshao_3_1/book.json').read_text(encoding='utf-8'))
        with fitz.open(pdf) as doc:
            for n in [12,17,24,42,57,67]:
                self.assertEqual(detect_scene_markers(doc[n-1]), [], n)
            for n in [8,11,13,14,18,29,33,39,53,61,66]:
                page=next(p for p in book['pages'] if p['pageIndex']==n)
                source=copy.deepcopy(page['sentences'])
                before={s['id']:(s['text'],s['rect']) for s in source}
                ordered,regions=prepare_page_dialogue(doc[n-1],source,reviewed.get(str(n)))
                numbered=[int(s['sceneId'].split('-')[1]) for s in ordered if (s['sceneId'] or '').startswith('scene-')]
                self.assertEqual(numbered,sorted(numbered),n)
                self.assertEqual(before,{s['id']:(s['text'],s['rect']) for s in ordered})
                if n==14:
                    group=[s['text'] for s in ordered if s['sceneId']=='scene-2']
                    self.assertEqual(group,["What’s your name?",'My name is Benny.'])
                if n==11:
                    dino=next(s for s in ordered if 'Dino Dinosaur' in s['text'])
                    self.assertEqual(dino['sceneId'],'scene-6')
                    self.assertEqual(dino['speaker'],'Dino')

    def test_generic_number_markers_and_no_marker_fallback(self):
        with fitz.open() as doc:
            page=doc.new_page(width=500,height=700)
            page.insert_text((30,300),'1',fontsize=12)
            page.insert_text((275,300),'2',fontsize=12)
            source=[entry("I'm nine.",.25,.2),entry('How old are you?',.3,.15),entry('Hello!',.2,.7)]
            ordered,_=prepare_page_dialogue(page,source)
            self.assertEqual([s['text'] for s in ordered],['How old are you?',"I'm nine.",'Hello!'])
            empty=doc.new_page()
            source=[entry('Thank you.',.1),entry('Hello!',.3)]
            ordered,_=prepare_page_dialogue(empty,source)
            self.assertEqual([s['text'] for s in ordered],['Thank you.','Hello!'])

    def test_tts_deduplicates_profiles_and_uses_supported_parameters(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);args=parser().parse_args([])
            entries=[{'id':str(i),'text':'Hello!', 'audioPath':f'assets/{i}.mp3',
                      **detect_speaker_and_voice('Hello!',{'speaker':who})}
                     for i,who in enumerate(['Dino','Dino','Peter'])]
            with patch('tools.build_textbook_assets.PROJECT_ROOT',root),patch('tools.build_textbook_assets.synthesize_http_audio',return_value=b'ID3'+b'a'*300) as remote:
                asyncio.run(synthesize(entries,args))
                self.assertEqual(remote.call_count,2)
                self.assertEqual(remote.call_args_list[0].args[0]['voice'],'test-dino')
                self.assertEqual(remote.call_args_list[0].args[0]['speedRatio'],1.06)
                self.assertEqual(remote.call_args_list[0].args[0]['text'],'Hello!')
                remote.reset_mock()
                asyncio.run(synthesize(entries,args))
                remote.assert_not_called()
                entries[0]['speedRatio']=0.8
                asyncio.run(synthesize(entries,args))
                remote.assert_called_once()


if __name__=='__main__': unittest.main()
