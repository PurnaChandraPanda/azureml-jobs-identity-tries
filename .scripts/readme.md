## Tips to follow in git
- go to root of repo

- run following script one time
```
gh version
sudo apt-get update && sudo apt-get install gh
gh auth login
./.scripts/bootstrap_github_repo.sh
```

- run following script for every check-in
```
gh auth login
./.scripts/git_push.sh "readme update"
```

