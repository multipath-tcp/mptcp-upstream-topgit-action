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
UPD_TG_FORCE_UPD_NET="${INPUT_FORCE_UPD_NET:-0}"

# Github remote
GIT_REMOTE_GITHUB_NAME="origin"

# Netdev remote
GIT_REMOTE_URL_NET="git://git.kernel.org/pub/scm/linux/kernel/git/netdev/net.git"
GIT_REMOTE_BRANCH_NET="master"
GIT_REMOTE_URL_NET_NEXT="git://git.kernel.org/pub/scm/linux/kernel/git/netdev/net-next.git"
GIT_REMOTE_BRANCH_NET_NEXT="master"

# Local repo
TG_TOPIC_BASE_NET_NEXT="net-next"
TG_TOPIC_BASE_NET="net"
TG_TOPIC_BASE_SHA_ORIG_NET_NEXT="${TG_TOPIC_BASE_NET_NEXT}" # will become a sha later
TG_TOPIC_BASE_SHA_ORIG_NET="${TG_TOPIC_BASE_NET}" # will become a sha later
TG_TOPIC_TOP_NET_NEXT="t/upstream"
TG_TOPIC_TOP_NET="${TG_TOPIC_TOP_NET_NEXT}-net"
TG_EXPORT_BRANCH_NET_NEXT="export"
TG_EXPORT_BRANCH_NET="${TG_EXPORT_BRANCH_NET_NEXT}-net"
TG_FOR_REVIEW_BRANCH_NET_NEXT="for-review"
TG_FOR_REVIEW_BRANCH_NET="${TG_FOR_REVIEW_BRANCH_NET_NEXT}-net"

ERR_MSG=""
TG_NEW_BASE_NET=0

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

topic_has_been_upstreamed() { local subject range
	subject="${1}"
	range="${2}"

	git log \
		--fixed-strings \
		-i --grep "${subject}" \
		--format="format:==%s==" \
		"${range}" | \
			grep -q --fixed-strings -i "==${subject}=="
}


###############
## TG Update ##
###############

# $1: branch
tg_update_base_github() { local branch
	branch="${1}"

	git_checkout "${branch}"

	git pull --no-stat --ff-only \
		"${GIT_REMOTE_GITHUB_NAME}" \
		"${branch}"
}

tg_update_base_local() {
	tg_update_base_github "${TG_TOPIC_BASE_NET}"
	TG_TOPIC_BASE_SHA_ORIG_NET=$(git_get_sha HEAD)

	tg_update_base_github "${TG_TOPIC_BASE_NET_NEXT}"
	TG_TOPIC_BASE_SHA_ORIG_NET_NEXT=$(git_get_sha HEAD)
}

tg_update_base_net_next() {
	if [ "${UPD_TG_NOT_BASE}" = 1 ]; then
		return 0
	fi

	git_checkout "${TG_TOPIC_BASE_NET_NEXT}"

	# this branch has to be in sync with upstream, no merge
	git pull --no-stat --ff-only \
		"${GIT_REMOTE_URL_NET_NEXT}" \
		"${GIT_REMOTE_BRANCH_NET_NEXT}"

	# if net-next is up to date, -net should be as well except if we force
	if [ "${UPD_TG_FORCE_SYNC}" != 1 ] && [ "${UPD_TG_FORCE_UPD_NET}" != 1 ] && \
	   [ "${TG_TOPIC_BASE_SHA_ORIG_NET_NEXT}" = "$(git_get_sha HEAD)" ]; then
		echo "Already sync with ${GIT_REMOTE_URL_NET_NEXT} (${TG_TOPIC_BASE_SHA_ORIG_NET_NEXT})"
		exit 0
	fi
}

tg_update_base_net() { local new_base
	if [ "${UPD_TG_NOT_BASE}" = 1 ]; then
		return 0
	fi

	git_checkout "${TG_TOPIC_BASE_NET}"

	# FETCH_HEAD == net/master
	git fetch "${GIT_REMOTE_URL_NET}" "${GIT_REMOTE_BRANCH_NET}"

	if [ "${UPD_TG_FORCE_UPD_NET}" = 1 ]; then
		new_base="FETCH_HEAD"
	else
		# to avoid having to resolve conflicts when merging -net and
		# net-next, we take the last common commit between the two
		new_base=$(git merge-base FETCH_HEAD "${TG_TOPIC_BASE_NET_NEXT}")

		if git merge-base --is-ancestor "${TG_TOPIC_BASE_NET}" "${new_base}"; then
			echo "Going to update the -net base (if new_base is different)"
		else
			echo "The -net base is newer than the common commit, no modif"
			new_base="${TG_TOPIC_BASE_NET}"
		fi
	fi

	# this branch has to be in sync with upstream, no merge
	git merge --no-stat --ff-only "${new_base}"

	if [ "${TG_TOPIC_BASE_SHA_ORIG_NET}" != "$(git_get_sha HEAD)" ]; then
		TG_NEW_BASE_NET=1
	fi
}

tg_update_abort_exit() {
	ERR_MSG+=": $(git_get_current_branch)"

	tg update --abort

	exit 1
}

# $1: git range of new commits
tg_update_resolve_or_exit() { local range subject
	range="${1}"

	subject=$(grep "^Subject: " .topmsg | cut -d\] -f2- | sed "s/^ //")

	if ! topic_has_been_upstreamed "${subject}" "${range}"; then
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

# $@: arg for tg_update_resolve_or_exit
tg_update() {
	if ! tg update; then
		tg_update_resolve_or_exit "${@}"

		while ! tg update --continue; do
			tg_update_resolve_or_exit "${@}"
		done
	fi
}

# $1: top branch, $2+: arg for tg_update_resolve_or_exit
tg_update_tree_common() { local branch
	branch="${1}"
	shift

	git_checkout "${branch}"

	# fetch and update-ref will be done
	tg remote "${GIT_REMOTE_GITHUB_NAME}" --populate

	# do that twice (if there is no error) just in case the base and the
	# rest of the tree were not sync. It can happen if the tree has been
	# updated by someone else and after, the base (only) has been updated.
	# At the beginning of this script, we force an update of the base.
	tg_update "${@}"
	tg_update "${@}"
}

tg_update_tree_net_next() { local range
	range="${TG_TOPIC_BASE_SHA_ORIG_NET_NEXT}..${TG_TOPIC_BASE_NET_NEXT}"

	tg_update_base_net_next

	tg_update_tree_common "${TG_TOPIC_TOP_NET_NEXT}" "${range}"

}

tg_update_tree_net() { local range
	range="${TG_TOPIC_BASE_SHA_ORIG_NET}..${TG_TOPIC_BASE_NET}"

	tg_update_base_net

	# first the tree for -net
	tg_update_tree_common "${TG_TOPIC_TOP_NET}" "${range}"

	# then the tree for net-next
	tg_update_tree_common "${TG_TOPIC_TOP_NET_NEXT}" "${range}"
}

tg_update_tree() {
	git fetch "${GIT_REMOTE_GITHUB_NAME}"

	# force to add TG refs in refs/top-bases/: needed for restrictions/clean-up
	git config --local topgit.top-bases refs

	tg_update_tree_net_next
	tg_update_tree_net
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
	# the bases should be already up to date anyway.
	git update-ref "refs/heads/${TG_TOPIC_BASE_NET}" \
		"refs/remotes/${GIT_REMOTE_GITHUB_NAME}/${TG_TOPIC_BASE_NET}"
	git update-ref "refs/heads/${TG_TOPIC_BASE_NET_NEXT}" \
		"refs/remotes/${GIT_REMOTE_GITHUB_NAME}/${TG_TOPIC_BASE_NET_NEXT}"
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

# $1: branch
tg_push() { local branch
	branch="${1}"

	git_checkout "${branch}"
	tg push -r "${GIT_REMOTE_GITHUB_NAME}"
}

tg_push_tree() {
	tg_push "${TG_TOPIC_TOP_NET_NEXT}"
	tg_push "${TG_TOPIC_TOP_NET}"
}

tg_export_common() { local branch_top branch_export current_date tag
	branch_top="${1}"
	branch_export="${2}"
	current_date="${3}"

	git_checkout "${branch_top}"

	tag="${branch_export}/${current_date}"

	tg export --force --notes "${branch_export}"

	# change the committer for the last commit to let Intel's kbuild starting tests
	GIT_COMMITTER_NAME="Matthieu Baerts" \
		GIT_COMMITTER_EMAIL="matthieu.baerts@tessares.net" \
		git commit --amend --no-edit

	git push --force "${GIT_REMOTE_GITHUB_NAME}" "${branch_export}"

	# send a tag to Github to keep previous commits: we might have refs to them
	git tag "${tag}" "${branch_export}"
	git push "${GIT_REMOTE_GITHUB_NAME}" "${tag}"
}

tg_export() { local current_date
	current_date=$(date --utc +%Y%m%dT%H%M%S)

	tg_export_common "${TG_TOPIC_TOP_NET_NEXT}" "${TG_EXPORT_BRANCH_NET_NEXT}" "${current_date}"

	if [ "${TG_NEW_BASE_NET}" = "1" ]; then
		tg_export_common "${TG_TOPIC_TOP_NET}" "${TG_EXPORT_BRANCH_NET}" "${current_date}"
	fi
}

tg_for_review_common() { local branch_top branch_review tg_conflict_files
	branch_top="${1}"
	branch_review="${2}"

	git_checkout "${branch_review}"

	git pull --no-stat --ff-only \
		"${GIT_REMOTE_GITHUB_NAME}" "${branch_review}"

	if ! git merge --no-edit --signoff "${branch_top}"; then
		# the only possible conflict would be with the topgit files, manage this
		tg_conflict_files=$(git status --porcelain | grep -E "^DU\\s.top(deps|msg)$")
		if [ -n "${tg_conflict_files}" ]; then
			echo "${tg_conflict_files}" | awk '{ print $2 }' | xargs git rm
			if ! git commit -s --no-edit; then
				err "Unexpected other conflicts: ${tg_conflict_files}"
				return 1
			fi
		else
			err "Unexpected conflicts when updating ${branch_review}"
			return 1
		fi
	fi

	git push "${GIT_REMOTE_GITHUB_NAME}" "${branch_review}"
}

tg_for_review() {
	tg_for_review_common "${TG_TOPIC_TOP_NET_NEXT}" "${TG_FOR_REVIEW_BRANCH_NET_NEXT}"

	if [ "${TG_NEW_BASE_NET}" = "1" ]; then
		tg_for_review_common "${TG_TOPIC_TOP_NET}" "${TG_FOR_REVIEW_BRANCH_NET}"
	fi
}


##########
## Main ##
##########

trap 'print_err "${?}"' EXIT

ERR_MSG="Unable to init git"
git_init

ERR_MSG="Unable to update the local topgit base"
tg_update_base_local

trap 'tg_trap_reset "${?}"' EXIT

ERR_MSG="Unable to update the topgit tree"
tg_update_tree

ERR_MSG="Unable to push the update of the Topgit tree"
tg_push_tree

ERR_MSG="Unable to export the TopGit tree"
tg_export

ERR_MSG="Unable to update the ${TG_FOR_REVIEW_BRANCH} branch"
tg_for_review
