#! /bin/bash -x
#
# The goal is to regularly sync 'net-next' branch on this repo with netdev's one.
# Then our topgit tree can be updated and the modifications can be pushed only
# if there were no merge conflicts.
#
# In case of questions about this script, please notify Matthieu Baerts.

# We should manage all errors in this script
set -e

# Env vars that can be set to change the behaviour
UPD_TG_FORCE_SYNC="${INPUT_FORCE_SYNC:-0}"
UPD_TG_NOT_BASE="${INPUT_NOT_BASE:-0}"

# Github remote
GIT_REMOTE_GITHUB_NAME="origin"

# Netdev remote
GIT_REMOTE_NET_NEXT_URL="git://git.kernel.org/pub/scm/linux/kernel/git/netdev/net-next.git"
GIT_REMOTE_NET_NEXT_BRANCH="master"

# Local repo
TG_TOPIC_BASE="net-next"
TG_TOPIC_BASE_SHA_ORIG="${TG_TOPIC_BASE}" # will become a sha later
TG_TOPIC_TOP="t/upstream"
TG_EXPORT_BRANCH="export"
TG_FOR_REVIEW_BRANCH="for-review"

ERR_MSG=""
TG_PUSH_NEEDED=0

###########
## Utils ##
###########

# $@: message to display before quiting
err() {
	echo "ERROR: ${*}" >&2
}

# $1: last return code
print_err() { local rc
	rc="${1}"

	# check return code: if different than 0, we exit with an error: reset
	if [ "${rc}" -eq 0 ]; then
		return 0
	fi

	# in the notif, only the end is displayed
	set +x
	err "${ERR_MSG}"

	return "${rc}"
}

git_init() {
	git config --global user.name "Jenkins Tessares"
	git config --global user.email "jenkins@tessares.net"
}

# $1: branch ;  [ $2: remote, default: origin ]
git_checkout() { local branch remote
	branch="${1}"
	remote="${2:-${GIT_REMOTE_GITHUB_NAME}}"

	git checkout -f "${branch}" || git checkout -b "${branch}" "${remote}/${branch}"
}

# [ $1: ref, default: HEAD ]
git_get_sha() {
	git rev-parse "${1:-HEAD}"
}

git_get_current_branch() {
	git rev-parse --abbrev-ref HEAD
}

topic_has_been_upstreamed() { local subject="${1}"
	git log \
		--fixed-strings \
		--grep "${subject}" \
		--format="format:==%s==" \
		"${TG_TOPIC_BASE_SHA_ORIG}..${TG_TOPIC_BASE}" | \
			grep -q --fixed-strings "==${subject}=="
}


###############
## TG Update ##
###############

tg_update_base() {
	git_checkout "${TG_TOPIC_BASE}"

	git pull --no-stat --ff-only \
		"${GIT_REMOTE_GITHUB_NAME}" \
		"${TG_TOPIC_BASE}" || return 1

	if [ "${UPD_TG_NOT_BASE}" = 1 ]; then
		return 0
	fi

	TG_TOPIC_BASE_SHA_ORIG=$(git_get_sha HEAD)

	# this branch has to be in sync with upstream, no merge
	git pull --no-stat --ff-only \
		"${GIT_REMOTE_NET_NEXT_URL}" \
		"${GIT_REMOTE_NET_NEXT_BRANCH}" || return 1
	if [ "${UPD_TG_FORCE_SYNC}" != 1 ] && \
	   [ "${TG_TOPIC_BASE_SHA_ORIG}" = "$(git_get_sha HEAD)" ]; then
		echo "Already sync with ${GIT_REMOTE_NET_NEXT_URL} (${TG_TOPIC_BASE_SHA_ORIG})"
		exit 0
	fi

	# Push will be done with the 'tg push'
	# in case of conflicts, the resolver will be able to sync the tree to
	# the latest valid state, update the base manually then resolve the
	# conflicts only once
	TG_PUSH_NEEDED=1
}

tg_update_abort_exit() {
	ERR_MSG+=": $(git_get_current_branch)"

	tg update --abort

	exit 1
}

tg_update_resolve_or_exit() { local subject
	subject=$(grep "^Subject: " .topmsg | cut -d\] -f2- | sed "s/^ //")

	if ! topic_has_been_upstreamed "${subject}"; then
		# display useful info in the log for the notifications
		git --no-pager diff || true

		tg_update_abort_exit
	fi

	echo "The commit '${subject}' has been upstreamed, trying auto-fix:"

	git checkout --theirs .
	git add -u
	git commit -s --no-edit

	if [ -n "$(tg files)" ]; then
		echo "This topic was supposed to be empty because the commit " \
		     "seems to have been sent upstream: abording."

		# display useful info in the log for the notifications
		tg patch || true

		tg_update_abort_exit
	fi
}

tg_update() {
	if ! tg update; then
		tg_update_resolve_or_exit

		while ! tg update --continue; do
			tg_update_resolve_or_exit
		done
	fi
}

tg_update_tree() {
	git_checkout "${TG_TOPIC_TOP}"

	git fetch "${GIT_REMOTE_GITHUB_NAME}"

	# force to add TG refs in refs/top-bases/, errit is configured for a
	# use with these refs and here below, we also use them.
	git config --local topgit.top-bases refs

	# fetch and update-ref will be done
	tg remote "${GIT_REMOTE_GITHUB_NAME}" --populate

	# do that twice (if there is no error) just in case the base and the
	# rest of the tree were not sync. It can happen if the tree has been
	# updated by someone else and after, the base (only) has been updated.
	# At the beginning of this script, we force an update of the base.
	tg_update
	tg_update
}

tg_get_all_topics() {
	git for-each-ref --format="%(refname)" "refs/remotes/${GIT_REMOTE_GITHUB_NAME}/top-bases/" | \
		sed -e "s#refs/remotes/${GIT_REMOTE_GITHUB_NAME}/top-bases/\\(.*\\)#\\1#g"
}

tg_reset() { local topic
	for topic in $(tg_get_all_topics); do
		git update-ref "refs/top-bases/${topic}" \
			"refs/remotes/${GIT_REMOTE_GITHUB_NAME}/top-bases/${topic}"
		git update-ref "refs/heads/${topic}" "refs/remotes/${GIT_REMOTE_GITHUB_NAME}/${topic}"
	done
	# the base should be already up to date anyway.
	git update-ref "refs/heads/${TG_TOPIC_BASE}" "refs/remotes/${GIT_REMOTE_GITHUB_NAME}/${TG_TOPIC_BASE}"
}

# $1: last return code
tg_trap_reset() { local rc
	rc="${1}"

	# print the error message is any.
	if print_err "${rc}"; then
		return 0
	fi

	tg_reset

	return "${rc}"
}


############
## TG End ##
############

tg_push_tree() {
	if [ "${TG_PUSH_NEEDED}" = "0" ]; then
		return 0
	fi

	git_checkout "${TG_TOPIC_TOP}"

	tg push -r "${GIT_REMOTE_GITHUB_NAME}"
}

tg_export() { local current_date tag
	git_checkout "${TG_TOPIC_TOP}"

	current_date=$(date +%Y%m%dT%H%M%S)
	tag="${TG_EXPORT_BRANCH}/${current_date}"

	tg export --linearize --force --notes "${TG_EXPORT_BRANCH}"

	# change the committer for the last commit to let Intel's kbuild starting tests
	GIT_COMMITTER_NAME="Matthieu Baerts" \
		GIT_COMMITTER_EMAIL="matthieu.baerts@tessares.net" \
		git commit --amend --no-edit

	git push --force "${GIT_REMOTE_GITHUB_NAME}" "${TG_EXPORT_BRANCH}"

	# send a tag to Github to keep previous commits: we might have refs to them
	git tag "${tag}" "${TG_EXPORT_BRANCH}"
	git push "${GIT_REMOTE_GITHUB_NAME}" "${tag}"
}

tg_for_review() { local tg_conflict_files
	git_checkout "${TG_FOR_REVIEW_BRANCH}"

	git pull --no-stat --ff-only \
		"${GIT_REMOTE_GITHUB_NAME}" "${TG_FOR_REVIEW_BRANCH}"

	if ! git merge --no-edit --signoff "${TG_TOPIC_TOP}"; then
		# the only possible conflict would be with the topgit files, manage this
		tg_conflict_files=$(git status --porcelain | grep -E "^DU\\s.top(deps|msg)$")
		if [ -n "${tg_conflict_files}" ]; then
			echo "${tg_conflict_files}" | awk '{ print $2 }' | xargs git rm
			if ! git commit -s --no-edit; then
				err "Unexpected other conflicts: ${tg_conflict_files}"
				return 1
			fi
		else
			err "Unexpected conflicts when updating ${TG_FOR_REVIEW_BRANCH}"
			return 1
		fi
	fi

	git push "${GIT_REMOTE_GITHUB_NAME}" "${TG_FOR_REVIEW_BRANCH}"
}


##########
## Main ##
##########

trap 'print_err "${?}"' EXIT

ERR_MSG="Unable to init git"
git_init

ERR_MSG="Unable to update the topgit base"
tg_update_base

trap 'tg_trap_reset "${?}"' EXIT

ERR_MSG="Unable to update the topgit tree"
tg_update_tree

ERR_MSG="Unable to push the update of the Topgit tree"
tg_push_tree

ERR_MSG="Unable to export the TopGit tree"
tg_export

ERR_MSG="Unable to update the ${TG_FOR_REVIEW_BRANCH} branch"
tg_for_review
