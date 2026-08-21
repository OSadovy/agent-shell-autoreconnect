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

(defun agent-shell-autoreconnect-tests--shell (client)
  "Make the current buffer look like a shell whose ACP state holds CLIENT."
  (setq major-mode 'agent-shell-mode)
  (setq-local agent-shell--state (list (cons :client client)))
  (setq-local agent-shell-autoreconnect-mode t))

(ert-deftest agent-shell-autoreconnect-connected-p-test ()
  "Test liveness is read from the ACP client's process."
  (with-temp-buffer
    ;; No process yet: bootstrapping has not reached one, so there is nothing
    ;; to reconnect and reporting a failure would invent one.
    (agent-shell-autoreconnect-tests--shell (list (cons :process nil)))
    (should (agent-shell-autoreconnect-connected-p)))
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

(provide 'agent-shell-autoreconnect-tests)

;;; agent-shell-autoreconnect-tests.el ends here
