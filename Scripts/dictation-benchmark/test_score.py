"""Regression tests for score.py. Expected counts are worked out by hand from
the strings, not by calling the scorer's own alignment.

Run: python3 -I -m unittest discover -s Scripts/dictation-benchmark
"""
import json
import os
import subprocess
import sys
import tempfile
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


class OutOfRangeRateTests(unittest.TestCase):
    def test_more_errors_than_words_keeps_the_rate_and_has_no_interval(self):
        # 1 reference word, right, plus 2 words on silence: 2 errors in 1 word.
        s = score([("go", "go"), ("", "uh um")])
        self.assertEqual((s["words"], s["I"], s["wer"]), (1, 2, 2.0))
        self.assertIsNone(s["wer95"])

    def test_only_empty_references_have_no_rate(self):
        s = score([("", "uh um")])
        self.assertEqual((s["words"], s["I"], s["empty_ref_words"]), (0, 2, 2))
        self.assertIsNone(s["wer"])
        self.assertIsNone(s["wer95"])

    def test_every_word_wrong_still_has_an_interval(self):
        # Wilson for 1 error in 1 word at z = 1.96: lower bound
        # 1 / (1 + 1.96^2) = 0.2065, upper bound 1.
        low, high = score([("go", "stop")])["wer95"]
        self.assertAlmostEqual(low, 0.2065, places=4)
        self.assertAlmostEqual(high, 1.0, places=9)


class ReportTests(unittest.TestCase):
    """Runs report.py as a user does and reads its printed line per cell."""

    def report(self, refs, rows):
        here = os.path.dirname(os.path.abspath(__file__))
        with tempfile.TemporaryDirectory() as folder:
            refs_path = os.path.join(folder, "refs.json")
            rows_path = os.path.join(folder, "results.jsonl")
            with open(refs_path, "w") as f:
                json.dump(refs, f)
            with open(rows_path, "w") as f:
                for row in rows:
                    f.write(json.dumps(row) + "\n")
            done = subprocess.run([sys.executable, "-I", os.path.join(here, "report.py"), refs_path, rows_path],
                                  capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        return {line.split()[0]: " ".join(line.split()) for line in done.stdout.splitlines()}

    def test_cells_where_a_proportion_is_undefined_still_report(self):
        refs = {"short": "go", "silence": "", "pair": "hello world"}
        lines = self.report(refs, [
            {"fixture": "short", "cell": "over", "text": "go"},
            {"fixture": "silence", "cell": "over", "text": "uh um"},
            {"fixture": "silence", "cell": "silent", "text": "uh um"},
            {"fixture": "pair", "cell": "plain", "text": "hello word"},
        ])
        # over: 2 insertions against 1 reference word, 200%.
        self.assertIn("words 1 S 0 D 0 I 2 WER 200.00% (95% n/a)", lines["over"])
        self.assertIn("silence words 2 in 1", lines["over"])
        # silent: 2 insertions against no reference words.
        self.assertIn("words 0 S 0 D 0 I 2 WER n/a (95% n/a)", lines["silent"])
        self.assertIn("silence words 2 in 1", lines["silent"])
        # plain: 1 substitution in 2 words; Wilson at z = 1.96 is
        # (0.5 +- 1.96 * sqrt(0.125 + 0.2401)) / 2.9208 with centre
        # 1.4604 / 2.9208 = 0.5, giving 9.45% to 90.55%.
        self.assertIn("words 2 S 1 D 0 I 0 WER 50.00% (95% 9.45-90.55%)", lines["plain"])


if __name__ == "__main__":
    unittest.main()
