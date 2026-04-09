# Managing Git Submodules Workflow

This workspace (`R-studioConf`) contains nested Git repositories configured as Git **Submodules** (such as the `Infra-Iam-PKI` directory).

Because a submodule is essentially an independent Git repository nested inside a parent repository, there is a specific workflow required to make changes, update code, and keep both repositories synchronized.

## Workflow 1: Pulling the Latest Updates from GitHub

If another developer has made changes to the submodule repository and you want to pull those updates down into your `R-studioConf` workspace, you can pull the remote changes directly:

```bash
# From the root of R-studioConf
git submodule update --remote Infra-Iam-PKI
```
This command tells Git to go fetch the latest commits from the remote repository and map them locally.

## Workflow 2: Making Changes and Pushing to the Submodule

When you want to edit files inside `Infra-Iam-PKI` and push those changes up to its own GitHub repository (`https://github.com/gsamuele78/Infra-Iam-PKI.git`), you must follow a two-part process. 

### Part A: Commit and Push from Inside the Submodule

First, navigate into the submodule folder and make sure you are on your working branch. Submodules often sit in a "detached HEAD" state, so it is critical that you checkout `main` (or your preferred branch) before making changes:

```bash
cd Infra-Iam-PKI
git checkout main
```

Now, make your changes to the files. Once you are done, commit and push them just like a normal repository:

```bash
git add .
git commit -m "My update to Infra-Iam-PKI"
git push origin main
```

*(At this point, your changes are successfully updated on the submodule's remote GitHub repository).*

### Part B: Update the Parent Repository (`R-studioConf`)

Because your submodule (`Infra-Iam-PKI`) now has a new commit, your parent repository (`R-studioConf`) needs to be told to update its tracker to remember this new version.

Navigate back out to your main workspace:

```bash
cd ..  # You are now back in the root of R-studioConf
```

Add the submodule folder (which now points to your new commit) and commit it into `R-studioConf`:

```bash
git add Infra-Iam-PKI
git commit -m "Update submodule Infra-Iam-PKI reference to latest commit"
git push
```

---

**Summary Rule of Thumb:** 
Whenever editing files in a nested submodule, you must `commit` and `push` from **inside the folder first**, then step out and `commit` the updated folder pointer to the **main repository**.
