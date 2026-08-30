# agent-shell-autoreconnect

Keep a remote agent-shell usable across a lost connection.

## What it's for

`agent-shell` starts the agent as a child of your connection. Point it at a
remote host — through
[agent-shell-tramp](https://github.com/junyi-hou/agent-shell-tramp), or an ssh
command prefix — and the agent process belongs to that ssh session. The adapter
exits when its stdin closes, so losing the connection kills the agent with it,
mid-turn.

A session daemon on the remote host, such as
[hydra-acp](https://github.com/smagnuso/hydra-acp), changes that: it owns the
agent, so the agent outlives the connection and keeps working while nothing is
attached.

The shell is what doesn't recover. Nothing tells you the connection went — an
idle shell looks the same either way — and there is no reconnect to reach for.
Send a prompt and `acp.el` quietly starts a fresh agent process, which was
never told about the session this buffer has been talking to, so the prompt
comes back with the agent reporting a session it doesn't know. The remedies
are `agent-shell-restart` and `agent-shell-reload`, and both hand you a new
buffer.

This package fills that in:

- **Tells you the connection went**, when it goes, not the next time you type.
- **Reconnects on your next prompt**, so a dropped connection costs a pause
  rather than a command, and your typed text is never eaten by a submission
  that couldn't happen.
- **Catches up on what you missed**, rendering whatever the agent said while
  nothing was attached into the buffer you already have.
- **Says when a session is beyond saving**, instead of insisting all is well.

All of it in the buffer you already have, which is the point — the
conversation is usually why you came back.

## Requirements

`agent-shell`, and an agent held by something that outlives your connection.

Developed and tested against [hydra-acp](https://github.com/smagnuso/hydra-acp),
a session daemon that keeps the agent running and journals what it says,
reached over TRAMP through a small stdio shim. Any daemon offering the same two
things should work: a session that survives the client, and a way to ask what
was said since a given point.

That second one is `session/attach`, which is not in ACP proper — it comes from
the still-unmerged [Multi-Client Session Attach
RFD](https://github.com/zed-industries/agent-client-protocol/pull/533). Without
it you still get reconnection; you don't get the catch-up.

## Setting up an agent behind hydra-acp

This package reconnects a remote shell; it does not create one. A working
setup needs three things.

**On the remote host**, the daemon running (see hydra-acp's own docs; under
`systemd --user` with `loginctl enable-linger` it survives logout), plus a
wrapper script that Emacs can start:

```sh
#!/bin/sh
# ~/bin/hydra-acp-shim
# Emacs starts this over a non-interactive ssh, which reads no profile, so
# neither node nor hydra-acp is on PATH.
NODE_DIR="$HOME/.nvm/versions/node/v24.19.0/bin"
PATH="$NODE_DIR:$PATH"
export PATH
exec "$NODE_DIR/hydra-acp" acp "$@"
```

**In Emacs**, a transport and an agent config:

```elisp
(use-package agent-shell-tramp
  :vc (:url "https://github.com/junyi-hou/agent-shell-tramp" :rev :newest)
  :config (agent-shell-tramp-mode 1))

(defun my-hydra-agent-config ()
  (agent-shell-make-agent-config
   :identifier 'claude-hydra
   :mode-line-name "Claude/hydra"
   :buffer-name "Claude hydra"
   :shell-prompt "Claude> "
   :shell-prompt-regexp "Claude> "
   :client-maker
   (lambda (buffer)
     ;; No credentials here: the agent runs on the server under the daemon
     ;; and uses that machine's.
     (agent-shell--make-acp-client
      :command "hydra-acp-shim"
      :context-buffer buffer))))

(with-eval-after-load 'agent-shell
  (setq agent-shell-agent-configs
        (lambda ()
          (append (agent-shell-default-agent-config-makers)
                  (list #'my-hydra-agent-config)))))
```

Then open a buffer on the remote host — a `/ssh:` or `/rpc:` directory — and
start the agent from there.

## Install

```elisp
(use-package agent-shell-autoreconnect
  :vc (:url "https://github.com/OSadovy/agent-shell-autoreconnect" :rev :newest)
  :hook (agent-shell-mode . agent-shell-autoreconnect-mode))
```

`:vc` needs Emacs 30, or `vc-use-package` on 29. From a local checkout
instead:

```elisp
(use-package agent-shell-autoreconnect
  :load-path "/path/to/agent-shell-autoreconnect"
  :hook (agent-shell-mode . agent-shell-autoreconnect-mode))
```

## Use

Mostly, don't. Submit prompts as usual; when the connection has gone you get a
pause instead of an error, and the conversation resumes where it left off.

| | |
|---|---|
| `M-x agent-shell-autoreconnect-reconnect` | Reconnect and catch up now, without sending a prompt — for getting the session back and up to date before you have anything to say. |
| `M-x agent-shell-autoreconnect-check` | Say whether this shell is connected. Reads local state only, so it answers instantly and cannot hang. |
| `M-x agent-shell-reload` | The exhaustive option: restart against the same session and replay all of it into a fresh buffer. |

The current state also shows in `mode-line-process`.

### What you get back after a reconnect

Everything the agent said while you were away, in the buffer you left. The one
seam is the message you were part-way through when the connection dropped: it
is rejoined rather than repeated, so you may re-read your own last prompt,
never the agent's answer.

If the daemon cannot honour the request — the conversation has moved on further
than it keeps — nothing is inserted and you are told the gap is still there,
rather than quietly receiving a second copy of the conversation.
`agent-shell-reload` is the fallback.

### When a session is gone for good

Removing a session on the server is not a disconnection: the connection is
healthy and the agent has simply forgotten the conversation. The shell reports
`session gone` and refuses further prompts. Nothing tries to recover it — a removed
session cannot be resumed, and the alternative is a new session with no memory
of any of this, which should be your decision.

## Connection hook

Besides the mode line, every change is published to a hook, so you can surface
it however you like.

```elisp
(add-hook 'agent-shell-autoreconnect-state-functions
          (lambda (event)
            (when (eq 'disconnected (map-elt event :state))
              (message "Agent connection lost"))))
```

Each function runs in the shell's buffer, with one alist:

```elisp
((:buffer . BUFFER)
 (:state  . connected | disconnected | reconnecting | session-gone))
```

State is reported only when it changes, so a handler may act on every call it
receives. Shells sharing a host fail within milliseconds of each other and are
reported separately, so a handler wanting one message for all of them has to
collect and settle them itself.

## Why reconnecting waits for you

Noticing a drop is free and happens by itself. Repairing one is not: starting
the agent again is a TRAMP call that cannot be bounded, and `with-timeout` is
disarmed inside TRAMP, so an unreachable host freezes Emacs for as long as it
takes. On a timer that freeze would arrive at a moment nothing explains.

So it happens only where a pause makes sense and `C-g` works: when you submit,
or when you ask.

A reconnect that fails — an unreachable host, an agent that dies part-way
through the handshake, or `C-g` through a connect taking too long — leaves the
shell as it was rather than half torn down: still disconnected, still holding
the session to resume, and still repairable by submitting again. Your typed
text stays in the input area, so retrying is one more `RET`.

## Tests

`agent-shell` is not loaded — the tests run against a fake ACP client — so
only `acp` has to be reachable.

```sh
emacs --batch -L . -L tests -L ~/.emacs.d/elpa/acp-* \
      -l tests/agent-shell-autoreconnect-tests.el \
      -f ert-run-tests-batch-and-exit
```
