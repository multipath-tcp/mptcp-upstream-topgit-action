# MPTCP Upstream TopGit Action

This action is specific to MPTCP Upstream repo to manage the TopGit tree in
[mptcp_net-next](https://github.com/multipath-tcp/mptcp_net-next) repo.

The idea here is to periodically sync the tree with upstream (net-next repo) and
publish the new tree to the repo if there were no merge conflicts.

## Inputs

### `force_sync`

Set it to 1 to force a sync even if net-next is already up to date. Default:
`0`.

### `not_base`

Set it to 1 to force a sync without updating the base from upstream. Default:
`0`.

## Example usage

```yaml
uses: multipath-tcp/mptcp-upstream-topgit-action@main
with:
  force_sync: '1'
```
