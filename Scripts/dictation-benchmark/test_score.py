"""Regression tests for score.py. Expected counts are worked out by hand from
the strings, not by calling the scorer's own alignment.

Run: python3 -I -m unittest discover -s Scripts/dictation-benchmark
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score import score  # noqa: E402


class EmptyReferenceTests(unittest.TestCase):
    def test_words_on_an_empty_reference_are_insertions(self):
        s = score([("", "uh")])
        self.assertEqual((s["words"], s["S"], s["D"], s["I"]), (0, 0, 0, 1))
        self.assertEqual((s["empty_refs"], s["empty_ref_words"]), (1, 1))
        self.assertEqual((s["edge_utts"], s["first_ok"], s["last_ok"]), (0, 0, 0))

    def test_pooled_rate_keeps_hallucinated_words(self):
        # 2 reference words, both right, plus 2 words on silence: 2 errors in 2.
        s = score([("hello world", "hello world"), ("", "uh um")])
        self.assertEqual((s["words"], s["I"]), (2, 2))
        self.assertEqual(s["wer"], 1.0)
        self.assertEqual((s["empty_refs"], s["empty_ref_words"]), (1, 2))

    def test_silent_hypothesis_on_silence_is_correct(self):
        s = score([("", "")])
        self.assertEqual((s["S"], s["D"], s["I"], s["empty_ref_words"]), (0, 0, 0, 0))

    def test_first_and_last_word_count_only_spoken_references(self):
        s = score([("the cat sat", "a cat sat"), ("one two", "one"), ("", "uh"), ("go", "go")])
        self.assertEqual(s["edge_utts"], 3)
        # "a" != "the"; "one" == "one"; "go" == "go"
        self.assertEqual(s["first_ok"], 2)
        # "sat" == "sat"; "one" != "two"; "go" == "go"
        self.assertEqual(s["last_ok"], 2)

    def test_a_silent_hypothesis_misses_both_edges(self):
        s = score([("hello", "")])
        self.assertEqual((s["D"], s["edge_utts"], s["first_ok"], s["last_ok"]), (1, 1, 0, 0))


if __name__ == "__main__":
    unittest.main()
