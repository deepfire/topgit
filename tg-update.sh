#!/bin/sh
# TopGit - A different patch queue manager
# (c) Petr Baudis <pasky@suse.cz>  2008
# GPLv2

name= # Branch to update
all= # Update all branches
pattern= # Branch selection filter for -a
current= # Branch we are currently on
method=rebase # Update method: rebase or merge

## Parse options

while [ -n "$1" ]; do
	arg="$1"; shift
	case "$arg" in
	-a|--all)
		all=1;;
	-r|--rebase)
		method=rebase;;
	-m|--merge)
		method=merge;;
	-*)
		echo "Usage: tg [...] update ([<name>] | -a [<pattern>...] | --all [<pattern>...]) [(-r | --rebase | -m | --merge)]" >&2
		exit 1;;
	*)
		if [ -z "$all" ]; then
			[ -z "$name" ] || die "name already specified ($name)"
			name="$arg"
		else
			pattern="$pattern refs/top-bases/${arg#refs/top-bases/}"
		fi
		;;
	esac
done
[ -z "$pattern" ] && pattern=refs/top-bases

current="$(git symbolic-ref HEAD 2>/dev/null | sed 's#^refs/\(heads\|top-bases\)/##')"
if [ -z "$all" ]; then
	if [ -z "$name" ]; then
		name="$current"
		base_rev="$(git rev-parse --short --verify "refs/top-bases/$name" 2>/dev/null)" ||
			die "not a TopGit-controlled branch"
	fi
else
	[ -n "$current" ] || die "cannot return to detached tree; switch to another branch"
fi

ensure_clean_tree

recursive_update() {
	$tg update ${methodflag}
	_ret=$?
	[ $_ret -eq 3 ] && exit 3
	return $_ret
}

update_branch() {
	local name="$1" base_rev depcheck missing_deps base_old_name base_update_cmd update_cmd ndeps must_merge HEAD
	info "; using $method mode to update $name"

	## First, take care of our base

	depcheck="$(get_temp tg-depcheck)"
	missing_deps=
	needs_update "$name" >"$depcheck" || :
	if [ -n "$missing_deps" ]; then
	   	if [ -z "$all" ]; then
		       	die "some dependencies are missing: $missing_deps"
		else
		       	info "some dependencies are missing: $missing_deps; skipping"
		       	return
		fi
	fi
	if [ -s "$depcheck" ]; then
		# We need to switch to the base branch
		# ...but only if we aren't there yet (from failed previous merge)
		base_old_name="refs/tmp/old-top-base-$(echo $name | sed 's#/#_#')"
		HEAD="$(git symbolic-ref HEAD)"
		if [ "$HEAD" = "${HEAD#refs/top-bases/}" ]; then
			switch_to_base "$name"
			git update-ref "${base_old_name}" $(git ref refs/top-bases/$name)
		fi
		
		# Can't quite rebase if there's more than one dependency, so let's
		# see if this is the case:
		ndeps=$(cat "$depcheck" | 
				   sed 's/ [^ ]* *$//' |
				   sed 's/.* \([^ ]*\)$/+\1/' |
				   sed 's/^\([^+]\)/-\1/' |
				   uniq -s 1 |
				   wc -l)
		if test $ndeps -gt 1; then
			must_merge=t
		fi
		cat "$depcheck" |
			sed 's/ [^ ]* *$//' | # last is $name
			sed 's/.* \([^ ]*\)$/+\1/' | # only immediate dependencies
			sed 's/^\([^+]\)/-\1/' | # now each line is +branch or -branch (+ == recurse)
			uniq -s 1 | # fold branch lines; + always comes before - and thus wins within uniq
			while read depline; do
				action="$(echo "$depline" | cut -c 1)"
				dep="$(echo "$depline" | cut -c 2-)"

				# We do not distinguish between dependencies out-of-date
				# and base/remote out-of-date cases for $dep here,
				# but thanks to needs_update returning : or %
				# for the latter, we do correctly recurse here
				# in both cases.

				if [ x"$action" = x+ ]; then
					info "Recursing to $dep..."
					git checkout -q "$dep"
					(
					export TG_RECURSIVE="[$dep] $TG_RECURSIVE"
					export PS1="[$dep] $PS1"
					while ! recursive_update; do
						# The merge got stuck! Let the user fix it up.
						info "You are in a subshell. If you abort the $method,"
						info "use \`exit 1\` to abort the recursive update altogether."
						info "Use \`exit 2\` to skip updating this branch and continue."
						if sh -i </dev/tty; then
							# assume user fixed it
							continue
						else
							ret=$?
							if [ $ret -eq 2 ]; then
								info "Ok, I will try to continue without updating this branch."
								break
							else
								info "Ok, you aborted the merge. Now, you just need to"
								info "switch back to some sane branch using \`git checkout\`."
								exit 3
							fi
						fi
					done
					)
					switch_to_base "$name"
				fi

				# This will be either a proper topic branch
				# or a remote base.  (branch_needs_update() is called
				# only on the _dependencies_, not our branch itself!)

				if test "$method" = "merge" || test ! -z "$must_merge"; then
					info "Merging $dep changes into base-of-$name..."
					base_update_cmd="git merge \"$dep\""
				else
					info "Rebasing base-of-$name on top of updated $dep..."
					base_update_cmd="git rebase \"$dep\""
				fi
			    
				if ! eval ${base_update_cmd}; then
					if [ -z "$TG_RECURSIVE" ]; then
						resume="\`git checkout $name && $tg update ${methodflag}\` again"
					else # subshell
						resume='exit'
					fi
					info "Merge conflict while doing a $method of base-of-$name with regard to $dep"
					info "Please commit merge resolution and call $resume."
					info "It is also safe to abort this operation using \`git reset --hard\`,"
					info "but please remember that you are on the base branch now;"
					info "you will want to switch to some normal branch afterwards."
					rm "$depcheck"
					exit 2
				fi
			done
	else
		info "The base of $name is up-to-date."
	fi

	# Home, sweet home...
	# (We want to always switch back, in case we were on the base from failed
	# previous merge.)
	git checkout -q "$name"

	merge_with="refs/top-bases/$name"


	## Second, update our head with the remote branch

	if has_remote "$name"; then
		rname="refs/remotes/$base_remote/$name"
		if branch_contains "$name" "$rname"; then
			info "The $name head is up-to-date wrt. its remote branch."
		else
			if test "$method" = "merge"; then
				info "Merging $dep changes into base-of-$name..."
				head_update_cmd="git merge \"$rname\""
			else
				info "Rebasing base-of-$name on top of updated $dep..."
				head_update_cmd="git rebase \"$rname\""
			fi
			info "Reconciling remote branch updates with $name base..."
			# *DETACH* our HEAD now!
			git checkout -q "refs/top-bases/$name"
			if ! eval ${head_update_cmd}; then
				info "Oops, you will need to help me out here a bit."
				info "Please commit merge resolution and call:"
				info "git checkout $name && git merge <commitid>"
				info "It is also safe to abort this operation using: git reset --hard $name"
				exit 4
			fi
			# Go back but remember we want to merge with this, not base
			merge_with="$(git rev-parse HEAD)"
			git checkout -q "$name"
		fi
	fi


	## Third, update our head with the base

	if branch_contains "$name" "$merge_with"; then
		info "The $name head is up-to-date wrt. the base."
		return 0
	fi
	info "Updating $name against new base..."
	if test "$method" = "rebase"; then
		if test ! -z "${base_old_name}"; then
			update_cmd="git rebase --onto \"${merge_with}\" \"${base_old_name}\""
		else
		    	update_cmd="git rebase \"${merge_with}\""
		fi
		if ! eval ${update_cmd}; then
			if [ -z "$TG_RECURSIVE" ]; then
				info "Please stage merge resolution. Then iterate with git rebase --continue, until it succeeeds."
				info "No need to do anything else"
				info "You can abort this operation using \`git rebase --abort\` now"
				info "and retry this merge later using \`$tg update ${methodflag}\`."
			else # subshell
				info "Please stage merge resolution. Then iterate with git rebase --continue,"
				info "until it succeeds.  Then call exit."
				info "You can abort this operation using \`git rebase --abort\`."
			fi
			exit 4
		fi
		if test ! -z "${base_old_name}"; then
			git update-ref -d "${base_old_name}"
		fi
	else
		if ! git merge "${merge_with}"; then
			if [ -z "$TG_RECURSIVE" ]; then
				info "Please commit merge resolution. No need to do anything else"
				info "You can abort this operation using \`git reset --hard\` now"
				info "and retry this merge later using \`$tg update ${methodflag}\`."
			else # subshell
				info "Please commit merge resolution and call exit."
				info "You can abort this operation using \`git reset --hard\`."
			fi
			exit 4
		fi
	fi
}

[ -z "$all" ] && { update_branch $name; exit; }

non_annihilated_branches $pattern |
	while read name; do
		info "Proccessing $name..."
		update_branch "$name" || exit
	done

info "Returning to $current..."
git checkout -q "$current"
# vim:noet
