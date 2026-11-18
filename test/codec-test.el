;;; codec-test.el --- Tests for codec -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for codec.el.  They need neither agent-shell, a microphone
;; nor a Whisper model: test/fake-listener.sh stands in for the
;; listener, and the agent-shell functions are stubbed.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'codec)

(unless (fboundp 'agent-shell-mode)
  (define-derived-mode agent-shell-mode fundamental-mode "Agent-Shell"
    "Stand-in for agent-shell's major mode."))

(defconst codec-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defvar codec-test--sent nil "The `agent-shell-insert' calls, newest first.")
(defvar codec-test--subscriptions nil
  "The `agent-shell-subscribe-to' calls, as (TOKEN BUFFER EVENT FUNCTION).")
(defvar codec-test--unsubscribed nil "Tokens given to `agent-shell-unsubscribe'.")
(defvar codec-test--busy nil "What the stubbed `shell-maker-busy' returns.")
(defvar codec-test--messages nil "Messages shown, newest first.")

(defun codec-test--wait-for (predicate &optional timeout)
  "Wait up to TIMEOUT seconds for PREDICATE to return non-nil."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall predicate)))

(defun codec-test--fire (buffer event)
  "Deliver agent-shell EVENT in BUFFER to its subscribers."
  (dolist (sub codec-test--subscriptions)
    (pcase-let ((`(,token ,sub-buffer ,sub-event ,function) sub))
      (when (and (eq sub-buffer buffer) (eq sub-event event)
                 (not (memq token codec-test--unsubscribed)))
        (funcall function `((:event . ,event)))))))

(defun codec-test--sent-texts ()
  "Return the texts sent to agent-shell, oldest first."
  (mapcar (lambda (call) (plist-get call :text)) (reverse codec-test--sent)))

(defmacro codec-test--with-env (&rest body)
  "Run BODY with stubs, the fake listener, and a clean `codec-mode'."
  (declare (indent 0) (debug t))
  `(let ((codec-test--sent nil)
         (codec-test--subscriptions nil)
         (codec-test--unsubscribed nil)
         (codec-test--busy nil)
         (codec-test--messages nil)
         (codec-listener-command
          (list "sh" (expand-file-name "fake-listener.sh" codec-test--directory)))
         (codec-listener-directory codec-test--directory)
         (codec-shutdown-timeout 3)
         (codec-after-send-functions nil)
         (counter 0)
         (buffers-before (buffer-list)))
     (ignore counter)
     (cl-letf (((symbol-function 'agent-shell-insert)
                (lambda (&rest args) (push args codec-test--sent)))
               ((symbol-function 'agent-shell-subscribe-to)
                (cl-function
                 (lambda (&key shell-buffer event on-event)
                   (push (list (cl-incf counter) shell-buffer event on-event)
                         codec-test--subscriptions)
                   counter)))
               ((symbol-function 'agent-shell-unsubscribe)
                (cl-function
                 (lambda (&key subscription)
                   (push subscription codec-test--unsubscribed))))
               ((symbol-function 'shell-maker-busy)
                (lambda () codec-test--busy))
               ((symbol-function 'message)
                (lambda (format-string &rest args)
                  (when format-string
                    (push (apply #'format-message format-string args)
                          codec-test--messages)))))
       (unwind-protect
           (progn ,@body)
         (codec-mode -1)
         (dolist (buffer (buffer-list))
           (unless (memq buffer buffers-before)
             (kill-buffer buffer)))))))

(defun codec-test--shell (name)
  "Return a new stand-in agent-shell buffer called NAME."
  (with-current-buffer (generate-new-buffer name)
    (agent-shell-mode)
    (current-buffer)))

(defun codec-test--start (&optional target)
  "Turn on `codec-mode' with TARGET current and wait for the listener."
  (with-current-buffer (or target (current-buffer))
    (codec-mode 1))
  (should (codec-test--wait-for (lambda () codec--ready))))

(defun codec-test--say (text)
  "Make the fake listener report TEXT as an utterance."
  (codec--send (concat "say " text)))

;;;; Wrapping

(ert-deftest codec-test-wrap-prepends-preamble-with-tags ()
  (let ((codec-voice-preamble "[voice] End with %ohi%c.  100%%.")
        (codec-spoken-open "<say>")
        (codec-spoken-close "</say>")
        (codec-preamble-position 'prepend))
    (should (equal (codec-wrap-transcript "run the tests")
                   "[voice] End with <say>hi</say>.  100%.\n\nrun the tests"))))

(ert-deftest codec-test-wrap-appends-preamble ()
  (let ((codec-voice-preamble "[voice] note")
        (codec-preamble-position 'append))
    (should (equal (codec-wrap-transcript "hello")
                   "hello\n\n[voice] note"))))

(ert-deftest codec-test-wrap-empty-preamble ()
  (let ((codec-voice-preamble ""))
    (should (equal (codec-wrap-transcript "hello") "hello"))))

(ert-deftest codec-test-default-preamble-names-the-tags ()
  (let ((text (codec-wrap-transcript "x")))
    (should (string-prefix-p "[voice] " text))
    (should (string-match-p (regexp-quote codec-spoken-open) text))
    (should (string-match-p (regexp-quote codec-spoken-close) text))
    (should (string-suffix-p "\n\nx" text))))

;;;; Sending

(ert-deftest codec-test-utterance-is-wrapped-and-sent ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*"))
          (hooked nil))
      (add-hook 'codec-after-send-functions
                (lambda (buffer text) (push (list buffer text) hooked)))
      (codec-test--start shell)
      (codec-test--say "Run the tests.")
      (should (codec-test--wait-for (lambda () codec-test--sent)))
      (let ((call (car codec-test--sent)))
        (should (equal (plist-get call :text)
                       (codec-wrap-transcript "Run the tests.")))
        (should (eq (plist-get call :submit) t))
        (should (eq (plist-get call :no-focus) t))
        (should (eq (plist-get call :shell-buffer) shell)))
      (should (equal hooked (list (list shell "Run the tests.")))))))

(ert-deftest codec-test-utterances-queue-while-busy ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (setq codec-test--busy t)
      (codec--handle-utterance "first")
      (codec--handle-utterance "second")
      (should-not codec-test--sent)
      (should (equal codec--queue '("first" "second")))
      (should (member "codec: agent busy; queued 2 utterance(s)"
                      codec-test--messages))
      ;; Still busy: a completed turn sends nothing yet.
      (codec-test--fire shell 'turn-complete)
      (accept-process-output nil 0.05)
      (should-not codec-test--sent)
      (setq codec-test--busy nil)
      (codec-test--fire shell 'turn-complete)
      (should (codec-test--wait-for (lambda () codec-test--sent)))
      (should (equal (codec-test--sent-texts)
                     (list (codec-wrap-transcript "first\n\nsecond"))))
      (should-not codec--queue))))

(ert-deftest codec-test-cancel-phrase-discards ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (setq codec-test--busy t)
      (codec--handle-utterance "Delete the build directory.")
      (codec--handle-utterance "Scratch that.")
      (should-not codec--queue)
      (should (equal (car codec-test--messages) "codec: discarded"))
      (setq codec-test--busy nil)
      (codec--handle-utterance "  CANCEL! ")
      (should (equal (car codec-test--messages) "codec: discarded"))
      (should-not codec-test--sent)
      (codec--handle-utterance "Cancel the deploy.")
      (should (equal (codec-test--sent-texts)
                     (list (codec-wrap-transcript "Cancel the deploy.")))))))

(ert-deftest codec-test-muted-drops-utterances ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (codec-mute)
      (codec--handle-utterance "hello")
      (should-not codec-test--sent)
      (should-not codec--queue)
      (codec-unmute)
      (codec--handle-utterance "hello")
      (should (equal (length codec-test--sent) 1)))))

(ert-deftest codec-test-filter-buffers-partial-lines ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (codec--filter codec--process "{\"type\":\"utter")
      (should-not codec-test--sent)
      (codec--filter codec--process "ance\",\"text\":\"caf\\u00e9\"}\nnot json\n{\"ty")
      (should (equal (codec-test--sent-texts)
                     (list (codec-wrap-transcript "café"))))
      (should (equal (process-get codec--process 'codec-pending) "{\"ty"))
      (with-current-buffer codec-log-buffer
        (should (string-match-p "not a protocol line: not json"
                                (buffer-string)))))))

(ert-deftest codec-test-stderr-goes-to-log-buffer ()
  (codec-test--with-env
    (codec-test--start (codec-test--shell "*agent-shell a*"))
    (should (codec-test--wait-for
             (lambda ()
               (with-current-buffer codec-log-buffer
                 (string-match-p "fake listener: --model" (buffer-string))))))))

;;;; Target

(ert-deftest codec-test-target-is-current-agent-shell ()
  (codec-test--with-env
    (let ((a (codec-test--shell "*agent-shell a*"))
          (b (codec-test--shell "*agent-shell b*")))
      (switch-to-buffer a)
      (codec-test--start b)
      (should (eq codec--target b))
      (should (equal (sort (mapcar (lambda (s) (nth 2 s))
                                   codec-test--subscriptions)
                           #'string<)
                     '(clean-up prompt-ready turn-complete))))))

(ert-deftest codec-test-target-is-most-recently-selected ()
  (codec-test--with-env
    (let ((a (codec-test--shell "*agent-shell a*"))
          (b (codec-test--shell "*agent-shell b*")))
      (switch-to-buffer a)
      (switch-to-buffer b)
      (with-temp-buffer
        (codec-test--start))
      (should (eq codec--target b)))))

(ert-deftest codec-test-no-target-starts-muted ()
  (codec-test--with-env
    (with-temp-buffer
      (codec-test--start))
    (should-not codec--target)
    (should (eq (codec-state) 'muted))
    (should (string-match-p "no agent-shell buffer" (car codec-test--messages)))
    (should-error (codec-unmute) :type 'user-error)
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-set-target shell)
      (should (eq codec--target shell))
      (should (eq (codec-state) 'listening)))))

(ert-deftest codec-test-set-target-moves-subscriptions ()
  (codec-test--with-env
    (let ((a (codec-test--shell "*agent-shell a*"))
          (b (codec-test--shell "*agent-shell b*")))
      (codec-test--start a)
      (codec-set-target b)
      (should (eq codec--target b))
      (should (equal (length codec-test--unsubscribed) 3))
      (should-error (codec-set-target (get-buffer-create "*scratch*"))
                    :type 'user-error)
      ;; Events from the old target are ignored.
      (setq codec-test--busy t)
      (codec--handle-utterance "hello")
      (setq codec-test--busy nil)
      (codec-test--fire a 'turn-complete)
      (accept-process-output nil 0.05)
      (should-not codec-test--sent)
      (codec-test--fire b 'turn-complete)
      (should (codec-test--wait-for (lambda () codec-test--sent))))))

(ert-deftest codec-test-dead-target-mutes ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (setq codec-test--busy t)
      (codec--handle-utterance "queued")
      (codec-test--fire shell 'clean-up)
      (kill-buffer shell)
      (should (codec-test--wait-for (lambda () (eq (codec-state) 'muted))))
      (should-not codec--target)
      (should-not codec--queue)
      (should (string-match-p "gone" (car codec-test--messages)))
      ;; It stays muted, and an utterance that was on its way is dropped.
      (codec--handle-utterance "hello")
      (should-not codec-test--sent)
      (should (eq (codec-state) 'muted)))))

(ert-deftest codec-test-target-killed-without-event ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (codec-unmute)
      (kill-buffer shell)
      (codec--handle-utterance "hello")
      (should-not codec-test--sent)
      (should (eq (codec-state) 'muted)))))

;;;; Mode line and lifecycle

(ert-deftest codec-test-mode-line-states ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (should (eq (codec-state) 'off))
      (with-current-buffer shell (codec-mode 1))
      (should (eq (codec-state) 'starting))
      (should (equal (substring-no-properties (codec--mode-line))
                     (alist-get 'starting codec-mode-line-states)))
      (should (codec-test--wait-for (lambda () (eq (codec-state) 'listening))))
      (should (equal (substring-no-properties (codec--mode-line)) " Codec:on"))
      (codec-mute)
      (should (eq (codec-state) 'muted))
      (codec-unmute)
      (should (eq (codec-state) 'listening))
      (codec-mode -1)
      (should (eq (codec-state) 'off)))))

(ert-deftest codec-test-listener-failure-is-error-state ()
  (codec-test--with-env
    (let ((process-environment
           (cons "CODEC_FAKE_FAIL=model load failed" process-environment)))
      (with-current-buffer (codec-test--shell "*agent-shell a*")
        (codec-mode 1))
      (should (codec-test--wait-for (lambda () (eq (codec-state) 'error))))
      (should (equal codec--error "model load failed"))
      (should (eq (get-text-property 0 'face (codec--mode-line)) 'error))
      (should (string-match-p "listener stopped" (car codec-test--messages)))
      ;; Turning the mode off and on again starts afresh.
      (codec-mode -1)
      (should-not codec--error))))

(ert-deftest codec-test-clean-shutdown ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (let ((process codec--process)
            (stderr codec--stderr-process))
        (codec-mode -1)
        (should-not (process-live-p process))
        ;; It quit by itself, not by a signal.
        (should (eq (process-status process) 'exit))
        (should (equal (process-exit-status process) 0))
        (should-not (process-live-p stderr))
        (should-not codec--process)
        (should-not codec--target)
        (should-not codec--error)
        (should (equal (length codec-test--unsubscribed) 3))
        (should-not (seq-some (lambda (m) (string-match-p "stopped" m))
                              codec-test--messages))))))

(ert-deftest codec-test-mute-requires-mode ()
  (should-not codec-mode)
  (should-error (codec-mute) :type 'user-error)
  (should-error (codec-unmute) :type 'user-error))

;;;; Listener command

(ert-deftest codec-test-listener-arguments ()
  (let ((codec-model "base.en")
        (codec-device 'auto)
        (codec-compute-type 'auto)
        (codec-silence-ms 700)
        (codec-drop-phrases '("okay" "bye"))
        (codec-listener-extra-args '("--beam-size" "1")))
    (should (equal (codec--listener-arguments)
                   '("--model" "base.en" "--device" "auto"
                     "--compute-type" "auto" "--silence-ms" "700"
                     "--drop-phrase" "okay" "--drop-phrase" "bye"
                     "--beam-size" "1")))))

(ert-deftest codec-test-listener-arguments-device ()
  (let ((codec-drop-phrases nil)
        (codec-listener-extra-args nil))
    (dolist (case '((cpu auto "cpu" "auto")
                    (mps "float16" "mps" "float16")
                    ("cuda" "int8_float16" "cuda" "int8_float16")))
      (let ((codec-device (nth 0 case))
            (codec-compute-type (nth 1 case)))
        (let ((args (codec--listener-arguments)))
          (should (equal (cadr (member "--device" args)) (nth 2 case)))
          (should (equal (cadr (member "--compute-type" args))
                         (nth 3 case))))))))

(ert-deftest codec-test-device-defaults ()
  (should (eq (default-value 'codec-device) 'auto))
  (should (eq (default-value 'codec-compute-type) 'auto)))

(ert-deftest codec-test-ready-names-the-device ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (should (equal codec--device "mps, int8_float16"))
      (should (member "codec: ready on mps, int8_float16" codec-test--messages))
      (should (string-match-p "listening on mps, int8_float16"
                              (plist-get (text-properties-at
                                          0 (codec--mode-line))
                                         'help-echo)))
      (with-current-buffer codec-log-buffer
        (should (string-match-p "ready on mps, int8_float16"
                                (buffer-string))))
      (codec-mode -1)
      (should-not codec--device))))

(ert-deftest codec-test-ready-without-device ()
  (codec-test--with-env
    (let ((codec--ready nil)
          (codec--muted-for-target nil)
          (codec--device 'stale))
      (codec--handle-line "{\"type\":\"ready\"}")
      (should codec--ready)
      (should-not codec--device)
      (should (member "codec: ready" codec-test--messages))
      (codec--handle-line "{\"type\":\"ready\",\"device\":\"cpu\",\"x\":[1]}")
      (should (equal codec--device "cpu")))))

(ert-deftest codec-test-default-command-uses-uv ()
  (let ((codec-listener-command nil)
        (codec-listener-directory "/tmp/codec-listener/")
        (codec-uv-program "sh"))
    (should (equal (codec--listener-base-command)
                   '("sh" "run" "--project" "/tmp/codec-listener/" "--frozen"
                     "--quiet" "python" "/tmp/codec-listener/codec_listener.py")))))

(ert-deftest codec-test-default-listener-directory ()
  (let ((codec-listener-directory nil))
    (should (file-exists-p (expand-file-name "codec_listener.py"
                                             (codec--listener-directory))))))

(provide 'codec-test)
;;; codec-test.el ends here
