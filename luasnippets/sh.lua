local ls = require 'luasnip'
local s = ls.snippet
local t = ls.text_node
local i = ls.insert_node
local f = ls.function_node
local c = ls.choice_node
local d = ls.dynamic_node
local sn = ls.snippet_node
local fmt = require('luasnip.extras.fmt').fmt
local rep = require('luasnip.extras').rep

-- These reach the *shell* command line, not just script files: readline's `v`
-- (edit-and-execute-command, reachable from vi-command mode under `set -o vi`
-- in .bash_vars) writes the pending line to /tmp/bash-fc.XXXXXX and opens
-- $EDITOR on it, and nvim's own filetype.lua matches `^bash%-fc[%-%.]` to sh
-- (runtime/lua/vim/filetype.lua:2713). So this file is already loaded in that
-- buffer with no ftdetect glue, and `:wq` hands the expansion back to bash to
-- run. Line continuations survive the round trip -- bash parses the file as
-- shell input, not as one line.
-- Nodes for `{<N>`: a whole brace expansion as `<base>{<word>,...}` with N
-- word stops, so N+1 stops in all and N words out. No element is prefilled or
-- forced empty; leaving the first stop blank is what gives back the old
-- `<base>{,<suffix>}` shape, where the empty element expands to the base word
-- alone. Tab stops run base (1) then left-to-right across the list (2..N+1).
-- N is a regex capture off the trigger, not another node, so there is nothing
-- to pass as dynamic_node's node_references arg (same shape as markdown.lua's
-- `tbl<N>`).
--
-- Floored at two words, so `{0` and `{1` both clamp up: bash needs a comma (or
-- a `..`) between the braces to treat them as an expansion at all, so a
-- one-element list would emit `<base>{<word>}` and be left standing literally,
-- braces and all -- never what was meant.
local function brace_nodes(_, snip)
  local words = math.max(tonumber(snip.captures[1]) or 2, 2)
  local nodes = { i(1), t '{' }
  for k = 1, words do
    if k > 1 then
      table.insert(nodes, t ',')
    end
    table.insert(nodes, i(k + 1))
  end
  table.insert(nodes, t '}')
  return sn(nil, nodes)
end

-- Default for `bft`'s init stop: the current release's single model, read at
-- each expansion from the metadata file every release PR rewrites, so it
-- tracks whatever is checked out. Rooted at nvim's cwd rather than the buffer,
-- because under readline's `v` the buffer lives in /tmp and only the cwd is
-- the shell's. Outside the repo the stop falls back to a label, which fails
-- loudly as a gs:// path instead of launching from a stale release.
local function release_single_path()
  local root = vim.fs.root(vim.fn.getcwd(), '.git')
  local meta = root and root .. '/onboard/models/joint_ilp_mh/model_release_metadata.json'
  if not (meta and vim.uv.fs_stat(meta)) then
    return sn(nil, i(1, 'init model dir (model_release_metadata.json not found)'))
  end
  return sn(nil, i(1, vim.json.decode(table.concat(vim.fn.readfile(meta), '\n')).single_path))
end

-- `btrain`/`bft`'s --config_path for the checkout, rooted the same way: `old`,
-- or the replacement launcher.sh's RETIRED_CONFIGS names once it refuses
-- `old`. Read from that table rather than tested by the replacement file
-- existing, because a replacement can predate the retirement
-- (train_eval_joint_ilp_mh.yaml by seven weeks). Outside the repo `old` stands.
local function launcher_config(old)
  local root = vim.fs.root(vim.fn.getcwd(), '.git')
  local launcher = root and root .. '/learning/behavior/workflow/launcher.sh'
  if launcher and vim.uv.fs_stat(launcher) then
    for _, line in ipairs(vim.fn.readfile(launcher)) do
      local new = line:match('%["' .. vim.pesc(old) .. '"%]="([^"]+)"')
      if new then
        return 'train_eval/' .. new
      end
    end
  end
  return 'train_eval/' .. old
end

-- Opt-out `|& clauderead` (.functions.sh): hand the run's output to claude,
-- prompt editable in the live choice. Cycled with <C-j>/<C-k> to the
-- commented-out copy. Must end the command's last line -- a backslash-continued
-- line after it would be swallowed by the comment.
local function clauderead_choice(pos)
  return c(pos, {
    sn(nil, { t '|& clauderead ', i(1, '/sb I ran this') }),
    t '# |& clauderead /sb I ran this',
  })
end

-- Field |k| (1 run id, 2 start, 3 end) of a `<run_id>_<start>_<end>` scene
-- string, split from the right the way the monorepo does (rsplit('_', 2), e.g.
-- learning/behavior/simteacher/redrive/fan_out.py:87): run ids may hold
-- underscores, timestamps cannot. A string that does not split gives `?`, so
-- the timestamps fail the pbtxt parse instead of submitting a wrong window.
local function scene_field(k)
  return function(args)
    return ({ args[1][1]:match '^(.+)_([^_]+)_([^_]+)$' })[k] or '?'
  end
end

-- `simtest`'s scenarios_selector line, cycled with <C-j>/<C-k>: a USM scene
-- set, one scene pasted as `<run_id>_<start>_<end>` and split into blob_info,
-- or blob_info filled field by field. The pasted string stays on the line as a
-- pbtxt comment, so the request records which scene it came from.
local function scenarios_selector_choice(pos)
  return c(pos, {
    -- A USM scene set db name, not a scenario set: those are a different
    -- oneof field and need usm_scenario_set instead.
    sn(nil, { t 'scenarios_selector { usm_scene_set: "', i(1, 'scene set name'), t '" }' }),
    sn(nil, {
      t 'scenarios_selector { blob_info { run_id: "',
      f(scene_field(1), { 1 }),
      t '" start_timestamp: ',
      f(scene_field(2), { 1 }),
      t ' end_timestamp: ',
      f(scene_field(3), { 1 }),
      t ' } }  # ',
      i(1, 'runid_start_end'),
    }),
    sn(nil, {
      t 'scenarios_selector { blob_info { run_id: "',
      i(1, 'run id'),
      t '" start_timestamp: ',
      i(2, 'start'),
      t ' end_timestamp: ',
      i(3, 'end'),
      t ' } }',
    }),
  })
end

local snippets = {
  -- `bce`: submit a Bates core-eval comparison job. The first three tab stops
  -- are the branch commit, the base prod tag, and the eval config; each carries
  -- the value used most often, so tabbing straight through accepts them and
  -- only the base tag normally needs retyping as prod moves each week. The
  -- last two are opt-in choices, commented out by default.
  s(
    'bce',
    fmt(
      [[
{{
branch=$(git rp --verify {}) && \
base=$(git rp --verify {}) && \
bazel run -c opt //behavior/core_eval/bates/scripts:submit_core_eval_comparison_job_main -- \
--base_commit $base \
--branch_commit $branch \
--email jke \
--config_name {} \
--post_processors_names DataFrameBinaryProcessor \
{}
}} {}]],
      {
        i(1, 'HEAD'),
        i(2, 'origin/prod/20260815'),
        i(3, 'bce_full'),
        -- Job name, cycled with <C-j>/<C-k> like `simtest`'s pose-divergence
        -- line. BCE has no tag flag, so this free-text name is the only label
        -- a job carries; left unset the orchestrator picks one
        -- (orchestration_client.py). The first choice is the flag commented
        -- out rather than empty so the option shows up in the expansion: the
        -- trailing backslash above splices it onto the previous line, where
        -- bash reads it as a comment.
        c(4, {
          t '# --job_name "put the job name"',
          sn(nil, { t '--job_name "', i(1, 'job name'), t '"' }),
        }),
        -- Lives after the brace group's `}` rather than on stop 4's line:
        -- bash splices continuations before stripping comments, so a
        -- commented-out job name would comment out the pipe too.
        clauderead_choice(5),
      }
    )
  ),
  -- `btrain`: launch a full cloud training run. The `--` gflags have to come
  -- before the bare `key=value` hydra overrides: launcher.py hands argv[1:] to
  -- hydra untouched and asserts every one of them splits on `=`, so a `--flag`
  -- trailing the overrides aborts the launch (launcher.py:56-58).
  -- Both stops carry the value used most often, so tabbing through accepts the
  -- BFM config; `email=jke` is enough because sanitize_corp_email appends the
  -- domain (utils/py/email_address.py:11). `tag` is the stop that has to be
  -- typed -- left empty the launcher names the run after the current branch
  -- rather than failing (tool/workflow/workflow_launcher_util.py:294).
  -- No `wandb_project=`: base/train_eval.yaml:11 already defaults it to null
  -- and only the rlms stages interpolate it, and passing it empty would set an
  -- empty string, not restore that null. Name a project only to split runs out
  -- of the shared behavior_training one.
  -- The config stop is prefilled by launcher_config().
  -- Expect prompts (BCE, base job, prediction eval): the BFM config enables
  -- those tasks and launcher.sh asks whenever stdin is a terminal.
  -- Passing `enabled_tasks=` or `use_base_commit=` here answers them up front.
  -- `mgbazel` (.functions.sh) because launcher.sh calls the bazel binary, not
  -- the shell's bazel() wrapper, so a server it starts would escape the
  -- bazel.slice memory cap. `bce` and `simtest` get the wrapper for free.
  s(
    'btrain',
    fmt(
      [[
mgbazel learning/behavior/workflow/launcher.sh \
--model=behavior_training \
--config_path={} \
email=jke \
tag={}]],
      {
        d(1, function()
          return sn(nil, i(1, launcher_config 'train_eval_bfm.yaml'))
        end, {}),
        i(2, 'tag'),
      }
    )
  ),
  -- `bft`: launch a finetune-only run from an existing model, skipping
  -- pretrain. Same launcher and override rules as `btrain` above. The config
  -- comes from launcher_config() and the init stop is prefilled by
  -- release_single_path(); the launcher passes the init path through
  -- unchecked, so a bad path only fails once train_bfm_finetune_tensorcraft
  -- loads it. The init key is the same under both configs: the block-based
  -- train_eval_joint_ilp_mh_finetune stage merges
  -- train_eval_bfm_finetune_tensorcraft (config/base/train_eval.yaml:815).
  s(
    'bft',
    fmt(
      [[
mgbazel learning/behavior/workflow/launcher.sh \
--model=behavior_training \
--config_path={} \
email=jke \
tag={} \
train_eval_bfm_finetune_tensorcraft.module_params.init_model_dir_or_weights={} {}]],
      {
        f(function()
          return launcher_config 'train_eval_bfm_finetune.yaml'
        end),
        i(1, 'tag'),
        d(2, release_single_path, {}),
        clauderead_choice(3),
      }
    )
  ),
  -- `simtest`: submit a unified-job simtest. Unified jobs take a scene set plus
  -- a variant rather than the legacy --categories, so the wiki's `n simtests
  -- run` does not apply here. The pbtxt heredoc is not decoration:
  -- configs_to_merge_paths -- how report mixins like create_video get pulled
  -- in -- has no CLI flag on submit_unified_job, and --request_proto_path is
  -- the only way to set it. Tab stops are labels, not defaults, so tabbing
  -- past one leaves a command that fails loudly rather than a wrong job; the
  -- variant and video lines are the exceptions and stay runnable as-is.
  -- Every line cyclable with <C-j>/<C-k> carries a `#` comment listing its
  -- options: on its own line above it where a continuation runs through
  -- (a comment after `&& \` would swallow the backslash), trailing on the
  -- last line, where clauderead's prompt words end before the `#`. The
  -- pbtxt ones are skipped by load_pbtxt like any `#` comment. The pbtxt braces are
  -- doubled because fmt eats single ones, and fmta is not an option here: its
  -- <> delimiters collide with the shell's > and <<. Choice-node text is not
  -- run through fmt, so the override line's braces stay single.
  -- The `&&` after <<'EOF' carries the chain past the heredoc body, so a failed
  -- fetch or lookup stops before bazel instead of submitting --commit="".
  s(
    'simtest',
    fmt(
      [[
# <C-j>/<C-k>: branch on origin | hash (must be on origin)
{}
req=$(mktemp -t simtest_req.XXXXXX.pbtxt) && cat > "$req" <<'EOF' &&
simulations_to_run {{
  # <C-j>/<C-k>: USM scene set | pasted runid_start_end | blob_info by field
  {}
  config_path: "fullstack"
  autonomy_config {{ variant: "{}" }}
  {}
  # <C-j>/<C-k>: end the sim at 50 m pose divergence | never end it early
  {}
}}
EOF
bazel run -c opt //simulation/framework/batch_simulation/request:submit_unified_job -- \
--email=jke \
--commit="$commit" \
--job_name="{}" \
--job_type=ui \
--request_proto_path="$req" {}  # <C-j>/<C-k>: pipe output to clauderead | don't]],
      {
        -- The commit to simulate, cycled with <C-j>/<C-k>. First a branch on
        -- origin, without the origin/ prefix, fetched by name: a branch pushed
        -- from another checkout or by a launcher has no origin/ ref here until
        -- then. Second a hash, full or abbreviated, which the GitHub API on
        -- origin's host resolves to the full sha -- a 404 means origin does
        -- not have it, and the sim workers can only build what origin has.
        -- Asked of the server because nothing local is both fast and true:
        -- `git fetch origin <sha>` skips the server when the object is
        -- already local, so an unpushed commit passes, and `git branch -r
        -- --contains` walks ~112k remote refs in the monorepo, minutes.
        -- The API also counts commits reachable only from PR refs; workers
        -- can fetch those too.
        c(3, {
          sn(nil, {
            t 'git fetch origin ',
            i(1, 'branch'),
            t { ' && \\', 'commit=$(git rp --verify origin/' },
            rep(1),
            t ') && \\',
          }),
          sn(nil, {
            t 'commit=$(GH_HOST=gitent.corp.nuro.team gh api repos/Nuro-ai/Nuro/commits/',
            i(1, 'hash'),
            t ' --jq .sha) && \\',
          }),
        }),
        scenarios_selector_choice(1),
        -- Which onboard config profile the stack runs with. Prefilled with
        -- scope12_bce, the usual one; unset falls back to
        -- scope12_controllable, which is rarely what you want.
        i(2, 'scope12_bce'),
        -- Video config, probably do not touch. Left as the literal line rather
        -- than a label so it is runnable untouched; clear the stop to drop the
        -- video and the blank line still parses as pbtxt.
        i(5, 'configs_to_merge_paths: "mixins/report_config/create_video.pbtxt"'),
        -- Pose-divergence cutoff, cycled with <C-j>/<C-k> like `repriori`'s
        -- fields. The simulator ends a sim once the sim ego is 50 m from the
        -- logged pose (simulator.cc MaybeEndSimulationFromPoseDivergence);
        -- the second choice turns that off, for when you need every scene's
        -- full window, e.g. to dump it with labels. Off by default because past
        -- 50 m the replayed agents no longer fit the ego. The first choice is
        -- the same line commented out rather than empty so the option shows up
        -- in the expansion; load_pbtxt skips pbtxt `#` comments.
        c(6, {
          t '# simulator_config { all_tasks_config { simulator_config_override_pbtxt: "disable_early_termination_from_pose_divergence: true" } }',
          t 'simulator_config { all_tasks_config { simulator_config_override_pbtxt: "disable_early_termination_from_pose_divergence: true" } }',
        }),
        -- Free text, no effect on behavior; it is what you scan for in the
        -- BATES task list, so make it say which scenario you are on.
        i(4, 'job name'),
        clauderead_choice(7),
      }
    )
  ),
  -- `simpersist`: keep a simtest job's NDFs past the 3-day default TTL
  -- (DEFAULT_SIMTEST_TTL, tool/simtest_retention_management/common.py:8).
  -- Persisting the job is the only route that works: copying an NDF elsewhere
  -- breaks it, since NDFs reference sibling directories in the job dir. Days
  -- count from now, not from the job start. Re-persisting an already-persisted
  -- job errors unless --update-description is added, and even then the TTL
  -- only ever grows (enforce_monotonic_update, retention_utils.py); use
  -- `extend-ttl <job> <days>` to add days to an existing row instead.
  s(
    'simpersist',
    fmt([[n simtests retention persist {} '{}' --days-to-retain={}]], {
      i(1, 'job id'),
      -- Required, and shown to platform when they chase storage cost.
      i(2, 'why keep it'),
      i(3, '30'),
    })
  ),
  -- `simpersisted`: list my persisted jobs, soonest expiry first, with job dir
  -- and days remaining. Caches are dropped because I never add any. For one
  -- job, `get-persisted-job-info <job>` answers whether it is persisted at all.
  s('simpersisted', t 'n simtests retention get-my-persisted --no-include-caches'),
  -- `simextend`: add days to an already-persisted job's TTL. The second arg is
  -- an increase, not a new total (the CLI names it DAYS_TO_INCREASE). Written
  -- `simtests` as above; `n simtest` also resolves, but this is the name the
  -- CLI's own usage line prints.
  s(
    'simextend',
    fmt([[n simtests retention extend-ttl {} {}]], {
      i(1, 'job id'),
      i(2, '30'),
    })
  ),
  -- `ndfaudio`: pull the mic audio behind each sim NDF from its onboard log,
  -- with the run id and window split off the NDF's name by `ndfscene`, a
  -- private shell function. The NDF stop takes gs:// paths or
  -- nurolog:// links, whitespace-separated, so a
  -- `$(bce JOB | xargs ndfpairs | cut -d' ' -f1)` fits there too; base and
  -- branch share the log, so one side is enough. Each NDF gets its own
  -- subdirectory because extract_audio_v2 writes a fixed <sensor_id>.wav per
  -- mic, which would overwrite across scenes. The output dir is made absolute
  -- up front: bazel run starts the binary in its runfiles tree, not here. A
  -- `for` over the list rather than piping ndfscene into `while read`, whose
  -- stdin bazel run would eat.
  s(
    'ndfaudio',
    fmt(
      [[
out=$(realpath -m {}) && \
for ndf in {}; do
  read -r run start end < <(ndfscene "$ndf") && \
  mkdir -p "$out/${{run}}_${{start}}_${{end}}" && \
  bazel run -c opt //perception/audio:extract_audio_v2 -- \
  --blob "$run" \
  --start_ts "$start" \
  --end_ts "$end" \
  --output_path "$out/${{run}}_${{start}}_${{end}}" || break
done]],
      { i(2, 'output dir'), i(1, 'ndf paths or nurolog:// links') }
    )
  ),
  -- `repriori`: build one row for the BATES GW prioritization sheet and leave it on
  -- the system clipboard, ready to paste into the leftmost empty cell of a new
  -- row -- Sheets splits pasted text on tabs, so one paste fills the row. The
  -- sheet has 12 columns (Date, Requester, Team/group, Organization,
  -- Justification, Company/Department blocking?, JobIDs, Priority, Tier, Status,
  -- Approver, Notes); this emits nine and stops, because Status/Approver/Notes
  -- are approver-only -- only the BATES team and TLMs hold edit access there,
  -- and the requeue service writes Complete/Rejected itself.
  --
  -- `tmux load-buffer -w` rather than a pipe to xclip: xclip would only reach
  -- this box's own X display, and the clipboard that matters is on the laptop at
  -- the far end of the ssh link. The terminal stream is the one channel that
  -- gets there, and OSC 52 is what rides it -- `-w` (tmux >= 3.2) asks tmux to
  -- emit it, the same route init.lua uses for nvim's clipboard over SSH.
  --
  -- `-t` is not decoration. A popup has no pane, so TMUX_PANE is unset inside
  -- one and tmux cannot resolve a current client; cmd-set-buffer.c gates the
  -- clipboard write on `tc != NULL` and CMD_CLIENT_CANFAIL keeps it quiet, so
  -- from a popup the buffer fills and the clipboard silently does not. Naming
  -- the client skips that resolution, and list-clients still answers correctly
  -- from a popup even though TMUX_PANE does not. Verified pasting from a popup
  -- on tmux 3.4. Braces are doubled because fmt eats single ones.
  --
  -- Raw OSC 52 straight out of a program in a popup -- nvim's own clipboard
  -- provider, say -- is a different code path (input.c returns early when
  -- wp == NULL) and stays broken until tmux 3.7, which Ubuntu 24.04 does not
  -- package. This command path does not depend on that fix.
  --
  -- Stops 1 and 2 are free text and carry their hint in the placeholder. Stops
  -- 3, 4 and 5 (blocking / priority / tier) are choice nodes instead, because
  -- their whole domain is three words or fewer: <C-j> / <C-k> cycles the
  -- options on those three fields (init.lua, next to <leader>rs), so the
  -- enumeration lives in the cycle rather than in placeholder text you would
  -- then have to delete before pasting. <C-u> lists them in a picker.
  --
  -- Which is only discoverable if it says so where you can see it, so the
  -- first emitted line is a `#` comment naming the cycle keys -- a comment
  -- here in the Lua is read when editing the snippet, never when using it.
  -- It costs nothing downstream: only printf's output reaches the clipboard,
  -- so the comment cannot land in a sheet cell, and bash ignores it whether
  -- the expansion is run as a script or handed back by readline's `v`
  -- (interactive_comments is on by default in an interactive shell). Delete
  -- the line if it is in the way; nothing depends on it.
  s(
    'repriori',
    fmt(
      [[
# <C-j>/<C-k> cycles the 'No' / 'P00' / 'generic' fields, <C-u> picks from a list
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
"$(date +%-m/%-d/%Y)" 'Jeffrey Ke' 'Behavior' 'Autonomy' \
'{}' '{}' '{}' '{}' '{}' \
| tmux load-buffer -w -t "$(tmux list-clients -F '#{{client_name}}' | head -1)" -]],
      {
        -- Should say why this job goes ahead of the queue, not just what it is;
        -- BATES and leadership read this column. A label, not a default: the
        -- loudest failure available for text output is an obviously-wrong cell
        -- staring back at you in the pasted row.
        i(1, 'justification (why this jumps the queue)'),
        -- Yes/No. Rarely Yes for us, so the common answer is first in the cycle.
        c(3, { t 'No', t 'Yes' }),
        -- Comma-separated, and every ID needs its namespace -- a bare ID
        -- silently defaults to simtest, which is how you end up prioritizing
        -- someone else's job or nothing at all.
        i(2, 'namespace/jobid (comma-separated, namespace required)'),
        -- P00 company-blocking, P0 department, P1 team.
        c(4, { t 'P00', t 'P0', t 'P1' }),
        -- generic <300 scenes, batch <10k, delayed <100k. The requeue service
        -- rejects the row outright if the job exceeds the tier's scene limit
        -- (generic 20k, batch 100k, delayed 1M), so oversize jobs want batch.
        c(5, { t 'generic', t 'batch', t 'delayed' }),
      }
    )
  ),
}

local autosnippets = {
  -- `{<N>` -> `<base>{<word>,...}` with N word stops, e.g. `{3` gives
  -- `|{|,|,|}` -- four tab stops, three words. Typed *before* the base word,
  -- unlike a plain closing-brace helper, because the leading stop is what lets
  -- one trigger build the whole expression: `cp -a ` then `{2` then fill in
  -- `config.yaml`, tab past the first list stop to leave it empty, and type
  -- `.bak` -- `cp -a config.yaml{,.bak}`.
  --
  -- An autosnippet, and regex-triggered, for the reason markdown.lua's
  -- `tbl(%d+)` is: blink.cmp labels a regex trigger with the raw Lua pattern,
  -- which cannot fuzzy-match what you actually type, so the completion menu is
  -- not a route to it. The InsertCharPre hook is.
  --
  -- TRAP: this trigger collides with ranges. `{1` is also the first two
  -- characters of `{1..10}`, so `for i in {1..10}` expands the snippet the
  -- moment you type the `1` -- there is no condition that can help, since the
  -- disambiguating `..` has not been typed yet. Living with it because ranges
  -- are `<C-r>`-recallable history far more often than they are freshly typed;
  -- if that turns out to be wrong, change the trigger to `{{(%d)` (`{{` is not
  -- valid shell, so nothing else can produce it) and nothing else here moves.
  -- `{([2-9])` is the cheaper half-fix -- it drops `{1` (and `{0`), the two
  -- captures the two-word floor was clamping anyway, so the only range still
  -- colliding is the rare `{2..N}` -- but it makes those two triggers silently
  -- do nothing rather than expand.
  --
  -- Only a single digit is captured: the hook fires on the first digit typed,
  -- so a `%d+` pattern could never see a second one anyway. `{9`, nine words,
  -- is the ceiling -- well past where a brace list stays readable.
  --
  -- `wordTrig = false` is load-bearing -- a regex trigger is still subject to
  -- it, and `{` sits mid-word often enough (`--out=dir{2`) to matter.
  --
  -- Nothing here re-closes the brace for us: kickstart's autopairs plugin is
  -- commented out (init.lua:1593) and the mini.nvim modules in use are `ai`
  -- and `surround`, neither of which inserts on `{`. Enabling autopairs would
  -- leave a stray `}` behind every expansion.
  --
  -- Note this is bash, not POSIX sh: dash leaves `{,.bak}` literal, so a
  -- script with a `#!/bin/sh` shebang wants both paths spelled out.
  s({ trig = '{(%d)', regTrig = true, wordTrig = false, desc = 'Brace expansion with N words: base{a,b}' }, { d(1, brace_nodes, {}) }),
}

return snippets, autosnippets
