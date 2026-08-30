;;; agent-shell-autoreconnect-tests.el --- Tests -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Run with:
;;
;;   emacs --batch -L . -L tests -l tests/agent-shell-autoreconnect-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-shell-autoreconnect)

;; agent-shell proper is not loaded here -- these tests run against a fake
;; client, and loading it would pull in a real one.  There `agent-shell--state'
;; is both a buffer-local variable and the function that reads it; the tests
;; set the variable, so the function has to be supplied.
(unless (fboundp 'agent-shell--state)
  (defun agent-shell--state () agent-shell--state))

(unless (fboundp 'agent-shell--active-requests-p)
  (defun agent-shell--active-requests-p (state) (map-elt state :active-requests)))

(defun agent-shell-autoreconnect-tests--shell (client)
  "Make the current buffer look like a shell whose ACP state holds CLIENT."
  (setq major-mode 'agent-shell-mode)
  (setq-local agent-shell--state (list (cons :client client)))
  (setq-local agent-shell-autoreconnect-mode t))

(ert-deftest agent-shell-autoreconnect-connected-p-test ()
  "Test liveness is read from the ACP client's process, and from its absence.

No process reads the same whether one is yet to start or has been and
gone, and those are opposite answers."
  (with-temp-buffer
    ;; No process yet: bootstrapping has not reached one, so there is nothing
    ;; to reconnect and reporting a failure would invent one.
    (agent-shell-autoreconnect-tests--shell (list (cons :process nil)))
    (should (agent-shell-autoreconnect-connected-p))
    ;; Had one, and it is gone -- a reconnect drops the client before
    ;; building its replacement.
    (setq agent-shell-autoreconnect--had-process t)
    (should-not (agent-shell-autoreconnect-connected-p)))
  (let ((process (start-process "agent-shell-autoreconnect-test" nil "sleep" "60")))
    (unwind-protect
        (with-temp-buffer
          (agent-shell-autoreconnect-tests--shell (list (cons :process process)))
          (should (agent-shell-autoreconnect-connected-p))
          (delete-process process)
          (should-not (agent-shell-autoreconnect-connected-p)))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest agent-shell-autoreconnect-reports-only-changes-test ()
  "Test a state is reported once, however often it is observed.

The connection is asked about on every submission, so reporting per
observation rather than per change would announce the same thing
repeatedly."
  (with-temp-buffer
    (agent-shell-autoreconnect-tests--shell (list (cons :process nil)))
    (let* ((seen nil)
           (agent-shell-autoreconnect-state-functions
            (list (lambda (event) (push (map-elt event :state) seen)))))
      (agent-shell-autoreconnect--report 'disconnected)
      (agent-shell-autoreconnect--report 'disconnected)
      (agent-shell-autoreconnect--report 'connected)
      (agent-shell-autoreconnect--report 'connected)
      (should (equal '(disconnected connected) (nreverse seen))))))

(ert-deftest agent-shell-autoreconnect-defers-argumentless-submit-test ()
  "Test a submission with no arguments is still sent after reconnecting.

`shell-maker-submit' is normally called with no arguments at all, so a
held submission cannot be recognised by its argument list being non-nil."
  (with-temp-buffer
    ;; A real client rather than a stub alist: finishing a reconnect
    ;; subscribes to the new client's notifications, and a subscription has
    ;; to be recorded on the client itself.
    (agent-shell-autoreconnect-tests--shell (acp-make-client :command "cat"))
    (let ((submitted 0))
      (cl-letf (((symbol-function 'shell-maker-submit)
                 (lambda (&rest _args) (setq submitted (1+ submitted)))))
        (setq agent-shell-autoreconnect--deferred (list nil))
        (agent-shell-autoreconnect--on-initialized nil)
        ;; Sending is deferred out of the event handler by a timer.
        (should (zerop submitted))
        (accept-process-output nil 0.2)
        (should (equal 1 submitted))
        (should-not agent-shell-autoreconnect--deferred)))))

(ert-deftest agent-shell-autoreconnect-passes-submit-through-when-connected-test ()
  "Test a live connection submits directly, without reconnecting."
  (with-temp-buffer
    (agent-shell-autoreconnect-tests--shell (list (cons :process nil)))
    (let ((reconnects 0))
      (cl-letf (((symbol-function 'agent-shell-autoreconnect--reconnect)
                 (lambda (&rest _args) (setq reconnects (1+ reconnects)))))
        (should (equal :sent (agent-shell-autoreconnect--submit
                              (lambda (&rest _args) :sent))))
        (should (zerop reconnects))))))

(ert-deftest agent-shell-autoreconnect-refuses-while-reconnecting-test ()
  "Test submitting during a reconnect is refused rather than queued twice."
  (with-temp-buffer
    (agent-shell-autoreconnect-tests--shell (list (cons :process nil)))
    (setq agent-shell-autoreconnect--state 'reconnecting)
    (should-error (agent-shell-autoreconnect--submit #'ignore) :type 'user-error)))

(ert-deftest agent-shell-autoreconnect-extends-anchor-by-count-not-overlap-test ()
  "Test the rejoin counts the first chunk rather than matching text.

The replay carries a message from its second chunk on, so part of it is
already on screen and has to be skipped.  Finding where by matching the
longest overlap between the two strings looks equivalent and is not: five
rendered \"a\"s against a replayed run of \"a\"s overlap as far as the
shorter one goes, so the join would skip too much and drop output that
arrived nowhere else.  Counting cannot be fooled that way."
  (with-temp-buffer
    (agent-shell-autoreconnect-tests--shell (list (cons :process nil)))
    (let (appended)
      (cl-letf (((symbol-function 'agent-shell--update-fragment)
                 (lambda (&rest args) (push (plist-get args :body) appended))))
        ;; "a" arrived as the first chunk and four more "a"s after it, so
        ;; two of the replayed six are genuinely new.
        (agent-shell-autoreconnect--extend-anchor
         (list :id "m" :namespace 1 :text "aaaaa" :first-length 1)
         "aaaaaa")
        (should (equal '("aa") appended))
        ;; Nothing new: the whole message had arrived before the drop.
        (setq appended nil)
        (agent-shell-autoreconnect--extend-anchor
         (list :id "m" :namespace 1 :text "hello world" :first-length 5)
         " world")
        (should-not appended)
        ;; Connected mid-message, so the recorded "first" chunk was not the
        ;; daemon's and the offset overshoots.  Clamped, and nothing is lost.
        (agent-shell-autoreconnect--extend-anchor
         (list :id "m" :namespace 1 :text "tail-end-only" :first-length 0)
         "short")
        (should-not appended)))))

(ert-deftest agent-shell-autoreconnect-takes-only-the-anchor-chunks-test ()
  "Test lifting the anchor's chunks leaves every other notification to render."
  (let* ((chunk (lambda (id text)
                  `((method . "session/update")
                    (params (update (sessionUpdate . "agent_message_chunk")
                                    (messageId . ,id)
                                    (content (text . ,text)))))))
         (prompt '((method . "session/update")
                   (params (update (sessionUpdate . "user_message_chunk")))))
         (state (list (cons :pending-restore
                            (list (cons :prompt-turns
                                        (list (list (funcall chunk "anchor" "BB")
                                                    (funcall chunk "anchor" "CC")
                                                    prompt
                                                    (funcall chunk "other" "ZZ"))))
                                  (cons :in-agent-response nil))))))
    (should (equal "BBCC" (agent-shell-autoreconnect--take-anchor-chunks state "anchor")))
    (should (equal (list (list prompt (funcall chunk "other" "ZZ")))
                   (map-nested-elt state '(:pending-restore :prompt-turns))))))

(ert-deftest agent-shell-autoreconnect-reports-a-process-that-dies-test ()
  "Test a connection that drops is noticed when it drops.

Without this the answer only arrives at the next prompt, which for someone
reading the buffer is indistinguishable from an agent still thinking."
  (let ((process (start-process "agent-shell-autoreconnect-test" nil "sleep" "60")))
    (unwind-protect
        (with-temp-buffer
          (agent-shell-autoreconnect-tests--shell (list (cons :process process)))
          (setq agent-shell-autoreconnect--state 'connected)
          (agent-shell-autoreconnect--watch-process process)
          (delete-process process)
          (accept-process-output nil 0.3)
          (should (eq 'disconnected agent-shell-autoreconnect--state)))
      (when (process-live-p process) (delete-process process)))))

(ert-deftest agent-shell-autoreconnect-ignores-a-process-it-ended-itself-test ()
  "Test the reconnect's own teardown is not reported as a disconnection.

Reconnecting ends the process on purpose.  Announcing that would report the
repair as the fault it is fixing, and leave the shell recorded as down at
the moment it is coming back up."
  (let ((process (start-process "agent-shell-autoreconnect-test" nil "sleep" "60")))
    (unwind-protect
        (with-temp-buffer
          (agent-shell-autoreconnect-tests--shell (list (cons :process process)))
          (setq agent-shell-autoreconnect--state 'reconnecting)
          (agent-shell-autoreconnect--watch-process process)
          (delete-process process)
          (accept-process-output nil 0.3)
          (should (eq 'reconnecting agent-shell-autoreconnect--state)))
      (when (process-live-p process) (delete-process process)))))

(ert-deftest agent-shell-autoreconnect-says-nothing-on-a-healthy-first-prompt-test ()
  "Test a shell that was never disconnected announces nothing when first used.

Submitting on a live connection reports `connected\='.  Starting from no
state at all made that a change, so the first prompt in a fresh shell
announced a reconnection that had not happened."
  (with-temp-buffer
    (setq major-mode 'agent-shell-mode)
    ;; Enabling the mode also subscribes to agent-shell's `error' event,
    ;; which is how a forgotten session is noticed.  agent-shell is not
    ;; loaded here, so stand that call in.
    (cl-letf (((symbol-function 'agent-shell-subscribe-to)
               (lambda (&rest _args) 'subscription)))
    ;; A real client, because enabling the mode subscribes to it.
    (setq-local agent-shell--state (list (cons :client (acp-make-client :command "cat"))))
    (let (seen)
      (let ((agent-shell-autoreconnect-state-functions
             (list (lambda (event) (push (map-elt event :state) seen)))))
        (agent-shell-autoreconnect-mode 1)
        (should (eq 'connected agent-shell-autoreconnect--state))
        (agent-shell-autoreconnect--submit (lambda (&rest _args) :sent))
        (should-not seen))))))

(ert-deftest agent-shell-autoreconnect-says-nothing-when-the-buffer-is-closing-test ()
  "Test killing a shell is not announced as a lost connection.

Closing a shell ends its agent, and the process dies while the buffer is
still live -- agent-shell tears the client down from `kill-buffer-hook'.
Read as a disconnection, that made every closed shell announce one."
  (let ((process (start-process "agent-shell-autoreconnect-test" nil "sleep" "60")))
    (unwind-protect
        (with-temp-buffer
          (agent-shell-autoreconnect-tests--shell (list (cons :process process)))
          (setq agent-shell-autoreconnect--state 'connected)
          (agent-shell-autoreconnect--watch-process process)
          (let (seen)
            (let ((agent-shell-autoreconnect-state-functions
                   (list (lambda (event) (push (map-elt event :state) seen)))))
              ;; What agent-shell's `clean-up' event sets, just before it
              ;; shuts the client down.
              (setq agent-shell-autoreconnect--closing t)
              (delete-process process)
              (accept-process-output nil 0.3)
              (should-not seen)
              (should (eq 'connected agent-shell-autoreconnect--state)))))
      (when (process-live-p process) (delete-process process)))))

(defun agent-shell-autoreconnect-tests--remote-shell (process)
  "Make the current buffer look like a shell connected over PROCESS.

Carries every key `agent-shell-autoreconnect--reconnect-in-place' writes,
because `map-put!' on an alist cannot add one."
  (setq major-mode 'agent-shell-mode)
  (setq-local agent-shell--state
              (list (cons :client (list (cons :process process)))
                    (cons :initialized t)
                    (cons :authenticated t)
                    (cons :active-requests nil)
                    (cons :resume-session-id nil)
                    (cons :session (list (cons :id "session-1")))))
  (setq-local agent-shell-autoreconnect-mode t)
  (setq agent-shell-autoreconnect--had-process t))

(defmacro agent-shell-autoreconnect-tests--with-failing-reconnect (signal &rest body)
  "Run BODY with a reconnect whose replacement process fails with SIGNAL.

Stubs only agent-shell, so the teardown and roll-back under test are real."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'agent-shell--shutdown) #'ignore)
             ((symbol-function 'agent-shell-subscribe-to)
              (lambda (&rest _) 'token))
             ((symbol-function 'agent-shell-unsubscribe) #'ignore)
             ((symbol-function 'agent-shell--handle)
              (lambda (&rest _)
                ;; Where a reconnect to an unreachable host dies: the
                ;; handshake is already recorded as in flight.
                (map-put! (agent-shell--state) :active-requests
                          (list (list (cons :method "initialize"))))
                ,signal)))
     ,@body))

(ert-deftest agent-shell-autoreconnect-rolls-back-a-quit-mid-reconnect-test ()
  "Test quitting a slow reconnect is undone the same as a failure.

A `quit' is not an `error', so catching only the latter lets it past the
roll-back, leaving the shell stuck at `reconnecting'.  What the roll-back
restores is covered where a failing reconnect is."
  (with-temp-buffer
    (agent-shell-autoreconnect-tests--remote-shell nil)
    (agent-shell-autoreconnect-tests--with-failing-reconnect (signal 'quit nil)
      ;; Not `should-error': it catches errors, and the point here is that a
      ;; quit is not one.
      (let ((quit nil))
        (condition-case nil
            (agent-shell-autoreconnect--reconnect)
          (quit (setq quit t)))
        (should quit)))
    (should (eq 'disconnected agent-shell-autoreconnect--state))))

(ert-deftest agent-shell-autoreconnect-leaves-a-failed-reconnect-repairable-test ()
  "Test a reconnect that cannot reach the host can still be retried.

One story, because either half alone leaves the shell stuck: without the
session id `agent-shell-submit' refuses before reaching the advice that
retries, and with it the submission must ask for another reconnect rather
than start a fresh agent that was never told this buffer's session."
  (with-temp-buffer
    (agent-shell-autoreconnect-tests--remote-shell nil)
    (agent-shell-autoreconnect-tests--with-failing-reconnect
        (signal 'file-error (list "Tramp failed to connect"))
      (should-error (agent-shell-autoreconnect--reconnect) :type 'file-error))
    (should (equal "session-1" (map-nested-elt (agent-shell--state) '(:session :id))))
    (should-not (map-elt (agent-shell--state) :active-requests))
    (should (eq 'disconnected agent-shell-autoreconnect--state))
    (let ((reconnects 0)
          (sent 0))
      (cl-letf (((symbol-function 'agent-shell-autoreconnect--reconnect)
                 (lambda (&rest _) (setq reconnects (1+ reconnects)))))
        (agent-shell-autoreconnect--submit (lambda (&rest _) (setq sent (1+ sent)))))
      (should (equal 1 reconnects))
      (should (zerop sent)))))

(ert-deftest agent-shell-autoreconnect-keeps-a-live-session-on-a-refused-reconnect-test ()
  "Test a reconnect refused before it starts does not adopt a stale session.

It still has its own session id, and `:resume-session-id' may name an
older one."
  (with-temp-buffer
    (agent-shell-autoreconnect-tests--remote-shell nil)
    (map-put! (agent-shell--state) :resume-session-id "an-older-session")
    (agent-shell-autoreconnect--roll-back)
    (should (equal "session-1" (map-nested-elt (agent-shell--state) '(:session :id))))))

(defun agent-shell-autoreconnect-tests--mid-reconnect ()
  "Leave the current buffer as a reconnect that has torn down but not rebuilt.

What `agent-shell-autoreconnect--reconnect-in-place' leaves once it has
started the replacement: no client, no session id, the id to resume put
aside, and the handshake in flight."
  (agent-shell-autoreconnect-tests--remote-shell nil)
  (map-put! (agent-shell--state) :client nil)
  (map-put! (agent-shell--state) :resume-session-id "session-1")
  (map-put! (agent-shell--state) :active-requests
            (list (list (cons :method "initialize"))))
  (map-put! (map-elt (agent-shell--state) :session) :id nil)
  (setq agent-shell-autoreconnect--state 'reconnecting)
  (setq agent-shell-autoreconnect--deferred (list nil))
  (setq agent-shell-autoreconnect--subscription 'token))

(ert-deftest agent-shell-autoreconnect-fails-a-reconnect-that-dies-handshaking-test ()
  "Test a replacement process that starts and then dies ends the reconnect.

The `condition-case' has returned by then and the sentinel watches the
process being replaced, so acp's failed request is the only signal.
Missed, the shell waits forever for an `init-finished'."
  (with-temp-buffer
    (cl-letf (((symbol-function 'agent-shell-unsubscribe) #'ignore))
      (agent-shell-autoreconnect-tests--mid-reconnect)
      (agent-shell-autoreconnect--on-error
       '((:data (:message . "Agent process ended before completing request"))))
      (should (eq 'disconnected agent-shell-autoreconnect--state))
      (should (equal "session-1" (map-nested-elt (agent-shell--state) '(:session :id))))
      (should-not (map-elt (agent-shell--state) :active-requests))
      (should-not agent-shell-autoreconnect--deferred)
      (should-not agent-shell-autoreconnect--subscription))))

(ert-deftest agent-shell-autoreconnect-reports-a-session-the-resume-could-not-find-test ()
  "Test a resume refused for a forgotten session says so, not `disconnected'.

Reconnecting is not the repair.  Recognising it means comparing against
the session id, which only exists again after the roll-back."
  (with-temp-buffer
    (cl-letf (((symbol-function 'agent-shell-unsubscribe) #'ignore))
      (agent-shell-autoreconnect-tests--mid-reconnect)
      (agent-shell-autoreconnect--on-error
       '((:data (:message . "Session session-1 not found"))))
      (should (eq 'session-gone agent-shell-autoreconnect--state)))))

(ert-deftest agent-shell-autoreconnect-leaves-an-ordinary-error-alone-test ()
  "Test an error on a working shell is not read as a failed reconnect.

Only a reconnect in progress turns every error into one."
  (with-temp-buffer
    (agent-shell-autoreconnect-tests--remote-shell nil)
    (setq agent-shell-autoreconnect--state 'connected)
    (let (seen)
      (let ((agent-shell-autoreconnect-state-functions
             (list (lambda (event) (push (map-elt event :state) seen)))))
        (agent-shell-autoreconnect--on-error
         '((:data (:message . "Tool call failed"))))
        (should-not seen)
        (agent-shell-autoreconnect--on-error
         '((:data (:message . "Session session-1 not found"))))
        (should (equal '(session-gone) seen))))))

(provide 'agent-shell-autoreconnect-tests)

;;; agent-shell-autoreconnect-tests.el ends here
