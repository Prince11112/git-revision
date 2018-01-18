import 'dart:async';
import 'dart:io';

import 'package:git_revision/git/git_commands.dart';
import 'package:git_revision/util/process_utils.dart';

class GitVersionerConfig {
  String baseBranch;
  String repoPath;
  int yearFactor;
  int stopDebounce;

  GitVersionerConfig(this.baseBranch, this.repoPath, this.yearFactor, this.stopDebounce)
      : assert(baseBranch != null),
        assert(yearFactor >= 0),
        assert(stopDebounce >= 0);
}

const Duration _YEAR = const Duration(days: 365);

class GitVersioner {
  final GitVersionerConfig config;

  GitVersioner(this.config);

  Future<int> _revision;

  Future<int> get revision async => _revision ??= () async {
        var commits = await baseBranchCommits;
        var timeComponent = await baseBranchTimeComponent;
        return commits.length + timeComponent;
      }();

  Future<LocalChanges> _localChanges;

  Future<LocalChanges> get localChanges => _localChanges ??= () async {
        //TODO implement
        return LocalChanges.NONE;
      }();

  Future<String> get versionName async {
    var rev = await revision;
    var branch = await branchName;
    var changes = await localChanges;
    var dirty = (changes == LocalChanges.NONE) ? '' : '-dirty';

    if (branch == config.baseBranch) {
      return "$rev$dirty";
    } else {
      var additionalCommits = await featureBranchCommits;
      return "${rev}_${branch}+${additionalCommits.length}${dirty}";
    }
  }

  Future<String> _currentBranch;

  Future<String> get branchName async => _currentBranch ??= time(() async {
        await _verifyGitWorking();
        var name = stdoutText(await Process.run('git', ['symbolic-ref', '--short', '-q', 'HEAD'])).trim();

        assert(() {
          if (name.split('\n').length != 1) throw new ArgumentError("branch name is multiline '$name'");
          return true;
        }());
        // empty branch names can't exits this means no branch name
        if (name.isEmpty) return null;
        return name;
      }(), 'branchName');

  Future<String> _sha1;

  Future<String> get sha1 async => _sha1 ??= time(() async {
        await _verifyGitWorking();
        var hash = stdoutText(await Process.run('git', ['rev-parse', 'HEAD'])).trim();

        assert(() {
          if (hash.isEmpty) throw new ArgumentError("sha1 is empty ''");
          if (hash.split('\n').length != 1) throw new ArgumentError("sha1 is multiline '$hash'");
          return true;
        }());

        return hash;
      }(), 'sha1');

  Future<List<Commit>> _commitsToHeadCache;

  Future<List<Commit>> get commitsToHead {
    return _commitsToHeadCache ??= time(_revList('HEAD'), 'allCommits');
  }

  Future<List<Commit>> _baseBranchCommits;

  Future<List<Commit>> get baseBranchCommits {
    return _baseBranchCommits ??= time(_revList(config.baseBranch), 'baseCommits');
  }

  Future<List<Commit>> _featureBranchCommits;

  Future<List<Commit>> get featureBranchCommits {
    return _featureBranchCommits ??= time(_revList('${config.baseBranch}..HEAD'), 'featureCommits');
  }

  /// runs `git rev-list $rev` and returns the commits in order new -> old
  Future<List<Commit>> _revList(String rev) async {
    // use commit date not author date. commit date is  the one between the prev and next commit. Author date could be anything
    var result =
        stdoutText(await Process.run('git', ['rev-list', '--pretty=%cI%n', rev], workingDirectory: config?.repoPath));
    return result.split('\n\n').where((c) => c.isNotEmpty).map((rawCommit) {
      var lines = rawCommit.split('\n');
      return new Commit(lines[0].replaceFirst('commit ', ''), DateTime.parse(lines[1]));
    }).toList(growable: false);
  }

  /// `null` when ready, errors otherwise
  Future<Null> _verifyGitWorking() async => null;

  Future<int> _baseBranchTimeComponent;

  Future<int> get baseBranchTimeComponent =>
      _baseBranchTimeComponent ??= baseBranchCommits.then((commits) => _timeComponent(commits));

  Future<int> _featureBranchTimeComponent;

  Future<int> get featureBranchTimeComponent =>
      _featureBranchTimeComponent ??= featureBranchCommits.then((commits) => _timeComponent(commits));

  int _timeComponent(List<Commit> commits) {
    assert(commits != null);
    if (commits.isEmpty) return 0;

    var completeTime = commits.last.date.difference(commits.first.date).abs();
    if (completeTime == Duration.zero) return 0;

    var completeTimeComponent = _yearFactor(completeTime);

    // find gaps
    var gaps = Duration.zero;
    for (var i = 1; i < commits.length; i++) {
      var prev = commits[i];
      // rev-list comes in reversed order
      var next = commits[i - 1];
      var diff = next.date.difference(prev.date).abs();
      if (diff.inHours >= config.stopDebounce) {
        gaps += diff;
      }
    }

    var gapTimeComponent = _yearFactor(gaps);
    var timeComponent = completeTimeComponent - gapTimeComponent;

    return timeComponent;
  }

  int _yearFactor(Duration duration) => (duration.inSeconds * config.yearFactor / _YEAR.inSeconds + 0.5).toInt();
}

const bool ANALYZE_TIME = false;

Future<T> time<T>(Future<T> f, String name) async {
  if (ANALYZE_TIME) {
    var start = new DateTime.now();
    var result = await f;
    var diff = new DateTime.now().difference(start);
    print('> $name took $diff');
    return result;
  } else {
    return await f;
  }
}
