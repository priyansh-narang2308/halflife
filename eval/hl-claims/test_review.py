import unittest

from review import kappa


class KappaTest(unittest.TestCase):
    def test_perfect_agreement(self):
        self.assertEqual(kappa(["A", "B"], ["A", "B"]), 1)

    def test_only_one_label_used(self):
        self.assertEqual(kappa(["A", "A"], ["A", "A"]), 1)

    def test_worked_example(self):
        # 20 AA, 5 AB, 10 BA, 15 BB: observed 0.70, expected 0.50.
        a = ["A"] * 25 + ["B"] * 25
        b = ["A"] * 20 + ["B"] * 5 + ["A"] * 10 + ["B"] * 15
        self.assertAlmostEqual(kappa(a, b), 0.4)


if __name__ == "__main__":
    unittest.main()
