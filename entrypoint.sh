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


##########################
## Check tools versions ##
##########################

check_sparse_version() { local last curr
	# Force a rebuild if a new version is available
	last=$(curl "${SPARSE_URL_BASE}" 2>/dev/null | \
		grep -o 'sparse-[0-9]\+\.[0-9]\+\.[0-9]\+\.tar' | \
		grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | \
		sort -uV | \
		tail -n1)
	curr=$(sparse --version)

	if [ "${curr}" = "${last}" ]; then
		echo "Using the last version of Sparse: ${curr}"
	else
		err "Not the last version of Sparse: ${curr} < ${last}"
		return 1
	fi
}


###############
## TG Update ##
###############

tg_update_base() { local sha_before_update
	git_checkout "${TG_TOPIC_BASE}"

	git pull --no-stat --ff-only \
		"${GIT_REMOTE_GITHUB_NAME}" "${TG_TOPIC_BASE}"

	if [ "${UPD_TG_NOT_BASE}" = 1 ]; then
		return 0
	fi

	sha_before_update=$(git_get_sha HEAD)

	# this branch has to be in sync with upstream, no merge
	git pull --no-stat --ff-only \
		"${GIT_REMOTE_NET_NEXT_URL}" "${GIT_REMOTE_NET_NEXT_BRANCH}"
	if [ "${UPD_TG_FORCE_SYNC}" != 1 ] && \
	   [ "${sha_before_update}" = "$(git_get_sha HEAD)" ]; then
		echo "Already sync with ${GIT_REMOTE_NET_NEXT_URL} (${sha_before_update})"
		exit 0
	fi

	# Push will be done with the 'tg push'
	# in case of conflicts, the resolver will be able to sync the tree to
	# the latest valid state, update the base manually then resolve the
	# conflicts only once
	TG_PUSH_NEEDED=1
}

tg_update() { local rc=0
	tg update || rc="${?}"

	if [ "${rc}" != 0 ]; then
		# display useful info in the log for the notifications
		git --no-pager diff || true

		tg update --abort
	fi

	return "${rc}"
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

	tg export --linearize --force "${TG_EXPORT_BRANCH}"

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

ERR_MSG="Environment is not up to date"
check_sparse_version

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
