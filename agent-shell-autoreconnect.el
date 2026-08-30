;;; agent-shell-autoreconnect.el --- Reconnect an agent shell on its own -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Oleksii Sadovyi

;; Author: Oleksii Sadovyi <lex.sadovyi@gmail.com>
;; URL: https://github.com/OSadovy/agent-shell-autoreconnect
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.73.4"))
;; Keywords: tools, processes

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Recovers a shell whose agent process ended, without killing the buffer:
;; reports whether each shell's connection is up, and reconnects on the next
;; prompt so a dropped connection costs a pause rather than a command.
;;
;; The case it is built for is an agent running on another machine, held by a
;; daemon that outlives the connection.  Close a laptop mid-turn and the agent
;; keeps working; the shell is talking to a process that is gone.  The session
;; is still there to be resumed, so the only thing missing is reconnecting to
;; it.
;;
;; agent-shell does not do that on its own.  `acp.el' starts a fresh process on
;; the next send, but nothing tells that process which session the buffer has
;; been talking to, so the prompt fails with the agent reporting a session it
;; never opened -- agent-shell issue #741.
;;
;; Nothing here runs on a timer.  Reconnecting means starting a process on the
;; remote host, and over TRAMP that is a synchronous call Emacs cannot bound --
;; `with-timeout' is disarmed inside TRAMP.  A timer that did this would freeze
;; the editor at a moment nothing explains, which for a screen reader user is
;; heard as silence.  So it happens when you submit a prompt, where a pause is
;; expected and `C-g' works.
;;
;; Connection changes go to `agent-shell-autoreconnect-state-functions' rather
;; than being spoken or displayed here, so the announcement can live wherever
;; it belongs -- Emacspeak, a notification, a mode line of your own.  A mode
;; line indicator is provided because it costs nothing; note that Emacspeak
;; speaks `mode-line-process' only as an auditory icon and never reads its
;; text, so a hook is the useful surface for speech, not this.
;;
;; Usage:
;;
;;   (add-hook 'agent-shell-mode-hook #'agent-shell-autoreconnect-mode)

;;; Code:

(require 'map)
(require 'seq)
(require 'acp)

;; Declared special so the binding around the replay is dynamic.  Left
;; lexical it would bind nothing agent-shell ever reads, and the trimming
;; this exists to disable would still happen.
(defvar agent-shell-session-restore-verbosity)

(declare-function agent-shell--state "agent-shell")
(declare-function agent-shell--shutdown "agent-shell" ())
(declare-function agent-shell--handle "agent-shell" (&rest args))
(declare-function agent-shell--active-requests-p "agent-shell" (state))
(declare-function agent-shell-subscribe-to "agent-shell" (&rest args))
(declare-function agent-shell-unsubscribe "agent-shell" (&rest args))
(declare-function shell-maker-submit "shell-maker")

(defgroup agent-shell-autoreconnect nil
  "Reconnect an agent shell whose agent process ended."
  :group 'agent-shell
  :prefix "agent-shell-autoreconnect-")

(defcustom agent-shell-autoreconnect-on-submit t
  "Whether submitting a prompt reconnects a shell whose connection is gone.

When nil, submitting into a dead connection fails the way it would
without this package, and `agent-shell-autoreconnect-reconnect' has to be
called by hand."
  :type 'boolean
  :group 'agent-shell-autoreconnect)

(defcustom agent-shell-autoreconnect-state-functions nil
  "Functions called when a shell's connection state changes.

Each is called with one alist, in the shell's buffer:

  ((:buffer . BUFFER)
   (:state  . `connected' | `disconnected' | `reconnecting' | `session-gone'))

Shells sharing a host fail within milliseconds of each other and each is
reported separately.  A handler that wants to speak once for all of them
has to collect and settle them itself; nothing here can, since no shell's
report knows another is about to follow.

`session-gone' is not a connection failure and reconnecting does not fix
it: the process is healthy and the agent has simply forgotten the session.
It is reported so that nothing keeps claiming the shell is fine, and left
there -- recovering means a session this one cannot resume.

State is reported only when it changes, so a handler is free
to announce every call it receives."
  :type 'hook
  :group 'agent-shell-autoreconnect)

(defvar-local agent-shell-autoreconnect--state nil
  "This shell's connection state as last reported, or nil before the first.")

(defvar-local agent-shell-autoreconnect--deferred nil
  "A submission held back while reconnecting, as a one-element list.

Wrapped rather than stored bare because `shell-maker-submit' is usually
called with no arguments at all, and an empty argument list is nil --
indistinguishable from having nothing to send.")

(defvar-local agent-shell-autoreconnect--subscription nil
  "Token for this shell's `init-finished' subscription, while one is live.")

(defvar-local agent-shell-autoreconnect--closing nil
  "Non-nil once this shell is being torn down.

A buffer being killed loses its agent on the way out, and that is not a
disconnection worth reporting -- there is nothing left to reconnect and
nobody to tell.")

(defvar-local agent-shell-autoreconnect--had-process nil
  "Whether this shell has ever had an agent process.

No process reads the same whether one is yet to start or has been and
gone, and `agent-shell-autoreconnect-connected-p' must answer those
oppositely.  Tracked on the process, not the client: `acp-make-client'
leaves `:process' nil until the first request.")

(defvar-local agent-shell-autoreconnect--cleanup-subscription nil
  "Token for this shell's `clean-up' subscription.")

(defvar-local agent-shell-autoreconnect--error-subscription nil
  "Token for this shell's `error' subscription.

Kept for the buffer's life rather than per connection: it is keyed on the
shell buffer, not on a client, so it survives the reconnects that replace
one.")

(defvar-local agent-shell-autoreconnect--anchor nil
  "The newest agent message seen live, and how much of it was rendered.

A plist of :id, :namespace, :text and :first-length.

:text and :first-length are what let a catch-up continue this message
rather than repeat it.  `session/attach' resolves `after_message' to a
message's *first* chunk and replays from the one after it, so naming the
newest message returns the rest of that same message -- of which some
arrived before the connection went.  Knowing the first chunk's length
says exactly how much, so the join is arithmetic.  Matching the two
strings for their longest overlap would be a guess, and a wrong one on
repetitive text: rendered \"aaaa\" against a replayed \"aaaa\" overlaps
fully, and the join would silently swallow real output.

:namespace because a fragment is addressed by id *and* the request count
current when it rendered, which the replay's own namespace differs from.")

(declare-function agent-shell--state "agent-shell")
(declare-function agent-shell--update-fragment "agent-shell" (&rest args))
(declare-function agent-shell--make-pending-restore "agent-shell" ())
(declare-function agent-shell--render-pending-restore "agent-shell" (state))

(defvar agent-shell-autoreconnect--advised nil
  "Whether the `shell-maker-submit' advice is installed.")

;;; Connection state

(defun agent-shell-autoreconnect--process (&optional buffer)
  "Return the ACP process of BUFFER's shell, or nil when there is none yet."
  (map-nested-elt (buffer-local-value 'agent-shell--state
                                      (or buffer (current-buffer)))
                  '(:client :process)))

(defun agent-shell-autoreconnect-connected-p (&optional buffer)
  "Return non-nil when BUFFER's shell has a live agent process.

A shell that has never started one counts as connected: agent-shell
starts it lazily, and reporting a failure that has not happened is noise.
A shell whose process is gone reads the same and means the opposite, so
the two are told apart by `agent-shell-autoreconnect--had-process'.  A
failed reconnect leaves that, and calling it connected means submitting
into a fresh agent that was never told this buffer's session."
  (let* ((buffer (or buffer (current-buffer)))
         (process (agent-shell-autoreconnect--process buffer)))
    (cond ((process-live-p process) t)
          (process nil)
          (t (not (buffer-local-value 'agent-shell-autoreconnect--had-process
                                      buffer))))))

(defun agent-shell-autoreconnect--report (state)
  "Report STATE for the current shell, when it is not already what was said.

Collapsing to the reported state rather than the transitions means a
connection that fails and retries several times is announced once, and a
state this package gains later cannot introduce new noise."
  (unless (or agent-shell-autoreconnect--closing
              (eq state agent-shell-autoreconnect--state))
    ;; Written before the handlers run, so a handler that looks at other
    ;; shells sees this one already counted, and a re-entrant call stops.
    (setq agent-shell-autoreconnect--state state)
    (setq mode-line-process
          (pcase state
            ('disconnected " [agent gone]")
            ('reconnecting " [reconnecting]")
            ('session-gone " [session gone]")
            (_ nil)))
    (force-mode-line-update)
    (run-hook-with-args 'agent-shell-autoreconnect-state-functions
                        (list (cons :buffer (current-buffer))
                              (cons :state state)))))

(defun agent-shell-autoreconnect-check ()
  "Report this shell's connection state, and return it.

Reads process state only, so it never contacts the remote host and cannot
block.  Interactively, this is the way to ask whether a silent shell is
working or disconnected."
  (interactive)
  (let ((state (if (agent-shell-autoreconnect-connected-p)
                   'connected
                 'disconnected)))
    (agent-shell-autoreconnect--report state)
    (when (called-interactively-p 'interactive)
      (message "%s" (pcase state
                      ('connected "Agent connected")
                      ('disconnected "Agent gone.  Submit a prompt to reconnect"))))
    state))

;;; Reconnecting

(defun agent-shell-autoreconnect--session-gone-p (message)
  "Whether MESSAGE says the agent no longer has this shell's session.

Matched on the session id as well as the wording, so an error that merely
mentions some session -- another shell's, or one named in passing -- is
not read as this one having been forgotten."
  (when-let* ((message)
              (id (map-nested-elt (agent-shell--state) '(:session :id))))
    (and (string-match-p (regexp-quote id) message)
         (string-match-p "not found" message))))

(defun agent-shell-autoreconnect--on-error (event)
  "Act on EVENT: a reconnect that failed, or a session the agent has forgotten.

A forgotten session arrives as a failed request, not a dead process: the
connection is healthy and only the session behind it is gone, so the
sentinel cannot see it.

While reconnecting, any error is that reconnect failing -- the handshake
is all that is in flight.  This is its only signal, because the
`condition-case' in `agent-shell-autoreconnect--reconnect' has long
returned and the sentinel watches the process being replaced.  Unhandled,
the shell waits forever for an `init-finished' that is not coming."
  (let ((message (map-nested-elt event '(:data :message))))
    (cond ((eq agent-shell-autoreconnect--state 'reconnecting)
           (agent-shell-autoreconnect--fail-reconnect message))
          ((agent-shell-autoreconnect--session-gone-p message)
           (agent-shell-autoreconnect--report 'session-gone)))))

(defun agent-shell-autoreconnect--watch-client ()
  "Watch this shell's ACP client, for both the ids and the moment it dies.

Called again after every reconnect, not just when the mode is enabled: a
reconnect hands the shell a *new* client, and both of these belong to the
client they were attached to.  Attaching once would leave the ids frozen at
whatever the dead client last saw, so a second disconnect would have no
cursor to resume from and could only report a gap."
  (when-let* ((client (map-elt (agent-shell--state) :client)))
    (acp-subscribe-to-notifications
     :client client
     :buffer (current-buffer)
     :on-notification #'agent-shell-autoreconnect--note-message-id)
    (agent-shell-autoreconnect--watch-process (map-elt client :process))))

(defun agent-shell-autoreconnect--watch-process (process)
  "Report this shell disconnected when PROCESS ends.

Noticing is free; it is reconnecting that is expensive, and conflating the
two is what makes a connection check look like something that has to wait
for a prompt.  A sentinel fires on its own when the process is reaped,
touches no remote host and cannot block, so the drop is announced when it
happens rather than the next time you happen to type.

Nothing here reconnects.  That would be a TRAMP call, and one made from a
sentinel would freeze Emacs at a moment nothing explains -- which is the
whole reason reconnection waits for a prompt or for
`agent-shell-autoreconnect-reconnect'.

A host that vanishes without closing the connection -- a closed lid, a
tunnel -- is noticed when ssh's keepalives give up rather than at once.
Later than the truth, but still by itself."
  (when (processp process)
    (setq agent-shell-autoreconnect--had-process t)
    (let ((buffer (current-buffer)))
      (add-function
       :after (process-sentinel process)
       (lambda (process _event)
         (unless (process-live-p process)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               ;; Not while reconnecting: that path ends this process itself,
               ;; and calling that a disconnection would report the repair as
               ;; the fault it is fixing.
               (unless (eq agent-shell-autoreconnect--state 'reconnecting)
                 (agent-shell-autoreconnect--report 'disconnected))))))
       '((name . agent-shell-autoreconnect))))))

(defun agent-shell-autoreconnect--note-message-id (notification)
  "Track NOTIFICATION's agent message as the anchor a catch-up resumes from.

Chunks of the message already being tracked extend it; a different id
starts a new anchor.  The text is accumulated as it goes past because it
is the record of what this buffer has actually been shown -- reading it
back off the screen afterwards would mean parsing rendered markdown, and
what is wanted is the wire text that produced it."
  (when-let* (((equal (map-elt notification 'method) "session/update"))
              ((equal (map-nested-elt notification '(params update sessionUpdate))
                      "agent_message_chunk"))
              (id (map-nested-elt notification '(params update messageId)))
              (text (or (map-nested-elt notification '(params update content text)) "")))
    (if (equal id (plist-get agent-shell-autoreconnect--anchor :id))
        (setq agent-shell-autoreconnect--anchor
              (plist-put agent-shell-autoreconnect--anchor :text
                         (concat (plist-get agent-shell-autoreconnect--anchor :text)
                                 text)))
      (setq agent-shell-autoreconnect--anchor
            (list :id id
                  :namespace (map-elt (agent-shell--state) :request-count)
                  :text text
                  :first-length (length text))))))

(defun agent-shell-autoreconnect--take-anchor-chunks (state id)
  "Remove ID's chunks from STATE's accumulated replay, returning their text.

They are the remainder of a message already on screen, so rendering them
where they stand would start a second copy of it below everything that
was genuinely missed.  Taken out here and rejoined to the original by
`agent-shell-autoreconnect--extend-anchor'."
  (let ((pending (map-elt state :pending-restore))
        (text ""))
    (map-put! pending :prompt-turns
              (mapcar
               (lambda (turn)
                 (seq-remove
                  (lambda (notification)
                    (when (and (equal (map-nested-elt notification '(params update sessionUpdate))
                                      "agent_message_chunk")
                               (equal (map-nested-elt notification '(params update messageId)) id))
                      (setq text (concat text (or (map-nested-elt notification '(params update content text)) "")))
                      t))
                  turn))
               (map-elt pending :prompt-turns)))
    text))

(defun agent-shell-autoreconnect--extend-anchor (anchor tail)
  "Append to ANCHOR's fragment whatever of TAIL is not already rendered.

TAIL is every chunk of the anchor message after its first, so what is
already on screen is however much of it arrived before the connection
went -- known exactly, because the chunks were counted as they passed.

The offset is clamped rather than trusted.  A shell that connected in the
middle of a message never saw that message's real first chunk, so its
idea of the offset can fall outside TAIL; erring low repeats a little
text, erring high would drop output that arrived nowhere else."
  (let* ((offset (max 0 (min (length tail)
                             (- (length (plist-get anchor :text))
                                (plist-get anchor :first-length))))))
    (when (< offset (length tail))
      (agent-shell--update-fragment
       :state (agent-shell--state)
       :namespace-id (plist-get anchor :namespace)
       :block-id (format "%s-agent_message_chunk" (plist-get anchor :id))
       :body (substring tail offset)
       :append t))))

(defun agent-shell-autoreconnect--catch-up ()
  "Ask for what was said while disconnected, and render it here.

The cursor is the newest message this buffer saw.  That is the one place
it can be: `after_message' replays from a message's second chunk onward,
so naming an *older* message would replay the turns between as well --
including the prompt typed here, which is already on screen and would
arrive a second time.  Naming the newest confines the overlap to a single
message, which `agent-shell-autoreconnect--extend-anchor' rejoins.

Nothing is altered until the daemon confirms it honoured the cursor: the
replay arrives before the response reporting which policy was applied, so
it is accumulated rather than rendered, and dropped untouched if the
cursor was not found."
  (if (null agent-shell-autoreconnect--anchor)
      (agent-shell-autoreconnect--report-gap)
    (let ((buffer (current-buffer))
          (anchor agent-shell-autoreconnect--anchor)
          (state (agent-shell--state)))
      ;; Suppresses rendering and accumulates instead, which is what makes
      ;; the decision below possible at all.
      (map-put! state :pending-restore (agent-shell--make-pending-restore))
      (acp-send-request
       :client (map-elt state :client)
       :buffer buffer
       :request (list (cons :method "session/attach")
                      (cons :params
                            (list (cons 'sessionId (map-nested-elt state '(:session :id)))
                                  (cons 'historyPolicy "after_message")
                                  (cons 'afterMessageId (plist-get anchor :id)))))
       :on-success (lambda (response)
                     (agent-shell-autoreconnect--apply-catch-up buffer anchor response))
       :on-failure (lambda (_error)
                     (agent-shell-autoreconnect--abandon-catch-up buffer))))))

(defun agent-shell-autoreconnect--apply-catch-up (buffer anchor response)
  "Render what BUFFER missed when RESPONSE honoured the cursor.

ANCHOR is the message the cursor named, whose remainder is lifted out of
the replay and rejoined to the copy already on screen."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (not (equal "after_message" (map-elt response 'historyPolicy)))
          ;; Fell back to a full replay because the cursor aged out of the
          ;; daemon's window.  Rendering it would duplicate the whole
          ;; conversation, so drop it and say the gap is still there.
          (agent-shell-autoreconnect--abandon-catch-up buffer)
        ;; Before rendering the rest: this continues a fragment sitting
        ;; above everything about to be inserted.
        (agent-shell-autoreconnect--extend-anchor
         anchor
         (agent-shell-autoreconnect--take-anchor-chunks
          (agent-shell--state) (plist-get anchor :id)))
        ;; `full' because the accumulated notifications are already only
        ;; what was missed; trimming them again would drop the same turns
        ;; twice.
        (let ((agent-shell-session-restore-verbosity 'full))
          (agent-shell--render-pending-restore (agent-shell--state)))
        (message "Reconnected, and caught up on what was missed")))))

(defun agent-shell-autoreconnect--abandon-catch-up (buffer)
  "Drop BUFFER's accumulated replay and report that a gap remains."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (map-put! (agent-shell--state) :pending-restore nil)
      (agent-shell-autoreconnect--report-gap))))

(defun agent-shell-autoreconnect--report-gap ()
  "Say that what was said while disconnected is not shown, and how to see it."
  (message
   "Reconnected.  Anything said while disconnected is not shown; %s"
   (substitute-command-keys "\\[agent-shell-reload] replays the session")))

(defun agent-shell-autoreconnect--on-initialized (_event)
  "Finish a reconnect: report it, catch up, then send whatever was held back."
  (agent-shell-autoreconnect--unsubscribe)
  (agent-shell-autoreconnect--report 'connected)
  ;; Before the catch-up, so the replay it is about to ask for advances the
  ;; cursor too and the disconnect after this one has somewhere to resume from.
  (agent-shell-autoreconnect--watch-client)
  (agent-shell-autoreconnect--catch-up)
  (when-let* ((held agent-shell-autoreconnect--deferred))
    (setq agent-shell-autoreconnect--deferred nil)
    ;; Out of the event handler before submitting: this runs inside
    ;; `agent-shell--handle', which submitting would re-enter.
    (run-at-time 0 nil
                 (lambda (buffer args)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (apply #'shell-maker-submit args))))
                 (current-buffer) (car held))))

(defun agent-shell-autoreconnect--unsubscribe ()
  "Drop this shell's `init-finished' subscription, when it has one."
  (when agent-shell-autoreconnect--subscription
    (ignore-errors
      (agent-shell-unsubscribe :subscription agent-shell-autoreconnect--subscription))
    (setq agent-shell-autoreconnect--subscription nil)))

(defun agent-shell-autoreconnect--reconnect-in-place ()
  "Reconnect the agent, keeping this buffer and its content.

Resets what belongs to the connection -- client, handshake,
authentication -- keeps the session id, and re-runs the initialization the
shell already performs lazily, resuming that session.

Unlike `agent-shell-restart', the buffer survives, and with it everything
subscribed to this shell."
  (unless (map-nested-elt (agent-shell--state) '(:session :id))
    (user-error "No session to reconnect to"))
  (when (and (agent-shell--active-requests-p (agent-shell--state))
             (process-live-p (map-nested-elt (agent-shell--state) '(:client :process))))
    (user-error "Agent is busy.  Interrupt it before reconnecting"))
  (map-put! (agent-shell--state) :resume-session-id
            (map-nested-elt (agent-shell--state) '(:session :id)))
  ;; Quietly: `acp-shutdown-client' answers "Client already shut down" for a
  ;; client whose process died, over the message explaining the pause.
  (let ((inhibit-message t))
    (agent-shell--shutdown))
  ;; `agent-shell--shutdown' clears these only while a client is still
  ;; recorded, and the next process has to re-handshake regardless.
  (map-put! (agent-shell--state) :client nil)
  (map-put! (agent-shell--state) :initialized nil)
  (map-put! (agent-shell--state) :authenticated nil)
  (map-put! (agent-shell--state) :active-requests nil)
  (map-put! (map-elt (agent-shell--state) :session) :id nil)
  ;; Resume rather than replay: the conversation is already on screen, and
  ;; loading it appends a second copy.  Buffer-local because initialization
  ;; finishes through callbacks, outliving a `let'.
  (setq-local agent-shell-session-restore-verbosity 'minimal)
  (agent-shell--handle :shell-buffer (current-buffer)))

(defun agent-shell-autoreconnect--roll-back ()
  "Undo the teardown of a reconnect that never rebuilt the connection.

`agent-shell-autoreconnect--reconnect-in-place' clears the session id
before starting the replacement, and `agent-shell-submit' refuses without
one -- before `shell-maker-submit', where the retrying advice lives.  So a
failure part way through leaves a shell that cannot reconnect at all.

Keyed on the missing session id, which only the teardown clears: a
reconnect refused before it started still has one, and its
`:resume-session-id' may name an older session."
  (let ((state (agent-shell--state)))
    (unless (map-nested-elt state '(:session :id))
      (map-put! (map-elt state :session) :id
                (map-elt state :resume-session-id))
      ;; The handshake is recorded as in flight and only its callbacks
      ;; remove it -- neither runs when the process never came up.
      (map-put! state :active-requests nil))))

(defun agent-shell-autoreconnect--fail-reconnect (&optional message)
  "Give up on the reconnect in progress, reporting what MESSAGE says of it.

Restores what the attempt tore down and stops waiting on it; anything left
behind makes one failed reconnect permanent.  The held submission is
dropped -- `agent-shell-autoreconnect--submit' never passed it on, so the
text is still in the input area.

Rolled back before MESSAGE is judged: recognising a forgotten session
needs the session id the roll-back restores."
  (agent-shell-autoreconnect--roll-back)
  (agent-shell-autoreconnect--unsubscribe)
  (setq agent-shell-autoreconnect--deferred nil)
  (agent-shell-autoreconnect--report
   (if (agent-shell-autoreconnect--session-gone-p message)
       'session-gone
     'disconnected)))

(defun agent-shell-autoreconnect--reconnect (&optional deferred)
  "Reconnect this shell, sending DEFERRED once it is up again.

DEFERRED is a held submission in the form `agent-shell-autoreconnect--deferred'
describes, or nil to reconnect without sending anything."
  (agent-shell-autoreconnect--unsubscribe)
  (setq agent-shell-autoreconnect--deferred deferred)
  (agent-shell-autoreconnect--report 'reconnecting)
  (setq agent-shell-autoreconnect--subscription
        (agent-shell-subscribe-to
         :shell-buffer (current-buffer)
         :event 'init-finished
         :on-event #'agent-shell-autoreconnect--on-initialized))
  (condition-case error
      (agent-shell-autoreconnect--reconnect-in-place)
    ;; `quit' as well as `error': C-g through a slow TRAMP connect is
    ;; expected, not exceptional.  Uncaught, it leaves the shell reporting
    ;; `reconnecting' with nothing reconnecting, refusing every submission.
    ((error quit)
     (agent-shell-autoreconnect--fail-reconnect)
     (signal (car error) (cdr error)))))

;;;###autoload
(defun agent-shell-autoreconnect-reconnect ()
  "Reconnect this shell now, without sending a prompt.

Submitting reconnects on its own, so this is for when there is nothing to
say yet -- opening the laptop and wanting the session back and caught up
before typing into it, rather than discovering the state by typing.

Deliberately a command and not a timer.  Starting the agent again is a
TRAMP call that cannot be bounded, so it happens where a pause is expected
and \\[keyboard-quit] works, never while you are reading something else."
  (declare (modes agent-shell-mode))
  (interactive)
  (unless (bound-and-true-p agent-shell-autoreconnect-mode)
    (user-error "Reconnection is not enabled in this buffer"))
  (when (eq agent-shell-autoreconnect--state 'reconnecting)
    (user-error "Reconnecting, please wait"))
  (when (eq agent-shell-autoreconnect--state 'session-gone)
    ;; Said before the liveness check, which would otherwise answer
    ;; "already connected" -- true of the process, and the wrong answer to
    ;; the question being asked.
    (user-error "Session no longer exists on the agent; this shell cannot be resumed"))
  (when (agent-shell-autoreconnect-connected-p)
    ;; Reported rather than only refused: being told it is already connected
    ;; is the answer the question was asking for.
    (agent-shell-autoreconnect--report 'connected)
    (user-error "Already connected"))
  (message "Reconnecting...")
  (agent-shell-autoreconnect--reconnect))

(defun agent-shell-autoreconnect--submit (original &rest args)
  "Reconnect before ORIGINAL sends ARGS, when this shell's agent is gone."
  (cond
   ((not (and (bound-and-true-p agent-shell-autoreconnect-mode)
              agent-shell-autoreconnect-on-submit))
    (apply original args))
   ((eq agent-shell-autoreconnect--state 'reconnecting)
    (user-error "Reconnecting, please wait"))
   ((eq agent-shell-autoreconnect--state 'session-gone)
    ;; Refused rather than passed through, which would consume the typed
    ;; text to produce the same error again.  Reconnecting is not the
    ;; repair either: there is nothing left to reconnect to.
    (user-error "Session no longer exists on the agent; this shell cannot be resumed"))
   ((agent-shell-autoreconnect-connected-p)
    (agent-shell-autoreconnect--report 'connected)
    (apply original args))
   (t
    ;; ORIGINAL is deliberately not called: it consumes the input area, and
    ;; a reconnect that fails would take the typed prompt with it.
    (message "Agent gone.  Reconnecting...")
    (agent-shell-autoreconnect--reconnect (list args)))))

;;; Mode

(defun agent-shell-autoreconnect--teardown ()
  "Release this shell's subscription and any held submission."
  (agent-shell-autoreconnect--unsubscribe)
  (setq agent-shell-autoreconnect--closing t)
  (dolist (slot '(agent-shell-autoreconnect--error-subscription
                  agent-shell-autoreconnect--cleanup-subscription))
    (when (symbol-value slot)
      (ignore-errors
        (agent-shell-unsubscribe :subscription (symbol-value slot)))
      (set slot nil)))
  (setq agent-shell-autoreconnect--deferred nil)
  (remove-hook 'kill-buffer-hook #'agent-shell-autoreconnect--teardown t)
  (remove-hook 'change-major-mode-hook #'agent-shell-autoreconnect--teardown t))

;;;###autoload
(define-minor-mode agent-shell-autoreconnect-mode
  "Reconnect this agent shell when its agent process has gone.

Reconnecting happens on the next prompt you submit, never on a timer.
`agent-shell-autoreconnect-check' reports the current state without
contacting anything."
  :lighter nil
  :group 'agent-shell-autoreconnect
  (cond
   (agent-shell-autoreconnect-mode
    ;; Starting from `connected' rather than from nothing.  A shell is
    ;; working when it is created, and leaving the state unset makes the
    ;; first prompt an edge from unknown to connected -- reported, and
    ;; announced, as though a connection had just come back that was never
    ;; away.  The first thing a new shell said was "agent reconnected".
    (setq agent-shell-autoreconnect--state 'connected)
    (unless agent-shell-autoreconnect--advised
      ;; Advising shell-maker rather than `agent-shell-submit' because
      ;; agent-shell sends some prompts (viewport compose, queued prompts)
      ;; straight through shell-maker, and those reach a dead connection too.
      (advice-add 'shell-maker-submit :around #'agent-shell-autoreconnect--submit)
      (setq agent-shell-autoreconnect--advised t))
    ;; Watching the raw stream, because the ids this needs are ACP fields
    ;; agent-shell reads for its own purposes and does not publish.  acp.el
    ;; keeps handlers in a list, so this runs alongside agent-shell's rather
    ;; than displacing it.
    (agent-shell-autoreconnect--watch-client)
    ;; A failed request is the only place a forgotten session shows up; no
    ;; process dies and no notification says so.
    (setq agent-shell-autoreconnect--error-subscription
          (agent-shell-subscribe-to
           :shell-buffer (current-buffer)
           :event 'error
           :on-event #'agent-shell-autoreconnect--on-error))
    ;; `clean-up' is emitted just before agent-shell shuts the client down for
    ;; a buffer being killed.  Without it the process dies while the buffer is
    ;; still live, and the sentinel calls that a disconnection.
    (setq agent-shell-autoreconnect--cleanup-subscription
          (agent-shell-subscribe-to
           :shell-buffer (current-buffer)
           :event 'clean-up
           :on-event (lambda (_event)
                       (setq agent-shell-autoreconnect--closing t))))
    (add-hook 'kill-buffer-hook #'agent-shell-autoreconnect--teardown nil t)
    (add-hook 'change-major-mode-hook #'agent-shell-autoreconnect--teardown nil t))
   (t
    (agent-shell-autoreconnect--teardown))))

(provide 'agent-shell-autoreconnect)

;;; agent-shell-autoreconnect.el ends here
