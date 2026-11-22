#!/usr/bin/env python3
"""Offline integration checks for OCR selection and project rule resolution."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RULES = ROOT / '.opencodereview/rule.json'


def run(*args, cwd=ROOT):
    return subprocess.run(args, cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


class ReviewRulesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if shutil.which('ocr') is None:
            raise RuntimeError('Install @alibaba-group/open-code-review@1.13.10 first')
        version = run('ocr', '--version')
        if ' v1.13.10 ' not in version:
            raise RuntimeError('These checks qualify OCR v1.13.10 only')
        scratch_value = os.environ.get('BATCH_RENAME_SCRATCH') or os.environ.get('TMPDIR')
        if not scratch_value:
            raise RuntimeError('Set BATCH_RENAME_SCRATCH or TMPDIR to a writable scratch directory')
        scratch = Path(scratch_value).resolve()
        if not scratch.is_dir() or scratch == Path('/private/tmp') or Path('/private/tmp') in scratch.parents:
            raise RuntimeError('Select an existing writable scratch directory outside system /tmp')
        cls.temp = tempfile.TemporaryDirectory(prefix='ocr-rules-', dir=scratch)
        cls.addClassCleanup(cls.temp.cleanup)
        cls.repo = Path(cls.temp.name)
        run('git', 'init', '-q', str(cls.repo))
        cls.paths = [
            'Sources/RenameCore/Core.swift', 'Sources/RenameCore/Updater.swift',
            'Sources/BatchRename/App.swift', 'Sources/BatchRename/AppUpdater.swift',
            'Tests/RenameCoreTests/CoreTests.swift', 'scripts/test-release-update.py',
            'workers/batch-rename/github-updates.test.mjs', 'workers/batch-rename/github-updates.mjs',
            'Resources/Info.plist', 'README.md', 'docs/UPDATES.md',
            '.env.scratch', 'release-assets/archive.json', 'build/generated.swift',
            'dist-next-v012/generated.swift', 'private.key', 'SAFETY-REVIEW.md',
        ]
        # Deliberately untracked fixtures exercise workspace selection, including secret paths.
        for name in cls.paths:
            path = cls.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture only\n')
        cls.config = json.loads(RULES.read_text())
        project = cls.repo / '.opencodereview/rule.json'
        project.parent.mkdir()
        project.write_text(json.dumps(cls.config))

    def preview(self, rule=None):
        args = ['ocr', 'delegate', 'preview', '--repo', str(self.repo), '--format', 'json']
        if rule:
            args += ['--rule', str(rule)]
        return json.loads(run(*args))

    def test_tests_and_release_metadata_are_included(self):
        data = self.preview()
        selected = {f['path'] for f in data['reviewable_files']}
        self.assertTrue(set(self.paths[:11]) <= selected)
        self.assertEqual(data['reviewable_count'], len(data['reviewable_files']))
        self.assertEqual(data['excluded_count'], len(data['excluded_files']))
        self.assertEqual(data['total_files'], data['reviewable_count'] + data['excluded_count'])

    def test_private_and_generated_files_are_excluded(self):
        data = self.preview()
        selected = {f['path'] for f in data['reviewable_files']}
        self.assertFalse(set(self.paths[11:]) & selected)
        excluded = {f['path']: f['exclude_reason'] for f in data['excluded_files']}
        self.assertEqual(excluded['.env.scratch'], 'secret_exclude')

    def test_specific_rules_win_and_keep_language_rules(self):
        data = json.loads(run('ocr', 'delegate', 'rule', '--repo', str(self.repo),
                              '--format', 'json', *self.paths[:8]))
        by_file = {p: g for g in data['groups'] for p in g['files']}
        expected = ['operates on user files', 'updater:', 'UI and model:',
                    'update orchestration:', 'regression tests:', 'regression tests:',
                    'regression tests:', 'distribution:']
        for name, text in zip(self.paths[:8], expected):
            group = by_file[name]
            self.assertEqual(group['source'], 'project')
            self.assertIn(text, group['rule'])
            self.assertIn('System-Specific Rules', group['rule'])
            self.assertIn('User-Specific Rules', group['rule'])

    def test_missing_includes_negative_control(self):
        config = dict(self.config, include=[])
        control = self.repo / 'without-includes.json'
        control.write_text(json.dumps(config))
        excluded = {f['path'] for f in self.preview(control)['excluded_files']}
        self.assertTrue({'Tests/RenameCoreTests/CoreTests.swift', 'Resources/Info.plist',
                         'README.md'} <= excluded)

    def test_missing_merge_negative_control(self):
        config = dict(self.config, rules=[dict(r, merge_system_rule=False) for r in self.config['rules']])
        control = self.repo / 'without-merge.json'
        control.write_text(json.dumps(config))
        data = json.loads(run('ocr', 'delegate', 'rule', '--repo', str(self.repo),
                              '--rule', str(control), '--format', 'json', self.paths[0]))
        self.assertNotIn('System-Specific Rules', data['groups'][0]['rule'])
        self.assertNotIn('Swift Review Principles', data['groups'][0]['rule'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
