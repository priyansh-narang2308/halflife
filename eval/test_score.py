import unittest

from score import interval, prf, score


class ScoreTest(unittest.TestCase):
    def test_prf(self):
        pairs = [(True, True), (True, False), (False, True), (False, False)]
        self.assertEqual(prf(pairs), (0.5, 0.5, 0.5))

    def test_nothing_stale_and_nothing_flagged_is_undefined(self):
        self.assertEqual(prf([(False, False)]), (None, None, None))

    def test_interval_is_seeded(self):
        pairs = [(True, True)] * 5 + [(True, False)] * 2 + [(False, True)]
        self.assertEqual(interval(pairs), interval(pairs))

    def test_s1_counts_false_as_stale(self):
        rows = [{"expected_verdict": "OUTDATED", "verdict": "CONTRADICTED"}]
        self.assertEqual(score("S1", rows)["stale_recall"], 1)
        self.assertEqual(score("S3", rows)["stale_recall"], 0)


if __name__ == "__main__":
    unittest.main()
