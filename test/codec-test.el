;;; codec-test.el --- Tests for codec -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for codec.el.  They need neither agent-shell, a microphone,
;; a Whisper model nor audio: test/fake-listener.sh stands in for the
;; listener, test/fake-tts.sh for say, Piper and the audio player, and
;; the agent-shell functions are stubbed.

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
(defvar codec-test--commands nil "Commands sent to the listener, newest first.")
(defvar codec-test--tts-log nil "The file where test/fake-tts.sh logs its runs.")

(defun codec-test--wait-for (predicate &optional timeout)
  "Wait up to TIMEOUT seconds for PREDICATE to return non-nil."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall predicate)))

(defun codec-test--fire (buffer event &optional data)
  "Deliver agent-shell EVENT with DATA in BUFFER to its subscribers."
  (dolist (sub codec-test--subscriptions)
    (pcase-let ((`(,token ,sub-buffer ,sub-event ,function) sub))
      (when (and (eq sub-buffer buffer) (eq sub-event event)
                 (not (memq token codec-test--unsubscribed)))
        (funcall function `((:data . ,data) (:event . ,event)))))))

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
         (codec-test--commands nil)
         (codec-test--tts-log (make-temp-file "codec-tts-log"))
         (codec-tts-backend 'say)
         (codec-say-program (expand-file-name "fake-tts.sh" codec-test--directory))
         (codec-say-voice nil)
         (codec-say-rate nil)
         (codec-spoken-max-chars 400)
         (codec-no-summary-text "Reply ready.")
         (codec-hide-spoken nil)
         (codec-spoken-position 'top)
         (codec-voice-preamble nil)
         (process-environment process-environment)
         (original-send (symbol-function 'codec--send))
         (counter 0)
         (buffers-before (buffer-list)))
     (ignore counter)
     (setenv "CODEC_FAKE_TTS_LOG" codec-test--tts-log)
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
               ((symbol-function 'codec--send)
                (lambda (command)
                  (push command codec-test--commands)
                  (funcall original-send command)))
               ((symbol-function 'message)
                (lambda (format-string &rest args)
                  (when format-string
                    (push (apply #'format-message format-string args)
                          codec-test--messages)))))
       (unwind-protect
           (progn ,@body)
         (codec-mode -1)
         (codec--reset-speech)
         (delete-file codec-test--tts-log)
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

(ert-deftest codec-test-preamble-follows-spoken-position ()
  (let ((codec-voice-preamble nil)
        (codec-preamble-position 'prepend))
    (let ((codec-spoken-position 'top))
      (should (string-match-p "Begin your reply with <spoken>"
                              (codec-wrap-transcript "x"))))
    (let ((codec-spoken-position 'bottom))
      (should (string-match-p "end your reply with <spoken>"
                              (codec-wrap-transcript "x"))))
    ;; A string of the user's own wins over both.
    (let ((codec-spoken-position 'bottom)
          (codec-voice-preamble "[voice] mine"))
      (should (equal (codec-wrap-transcript "x") "[voice] mine\n\nx")))))

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
                     '(agent-message-chunk clean-up prompt-ready
                                           turn-complete))))))

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
      (should (equal (length codec-test--unsubscribed) 4))
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
        (should (equal (length codec-test--unsubscribed) 4))
        (should-not (seq-some (lambda (m) (string-match-p "stopped" m))
                              codec-test--messages))))))

(ert-deftest codec-test-mute-requires-mode ()
  (should-not codec-mode)
  (should-error (codec-mute) :type 'user-error)
  (should-error (codec-unmute) :type 'user-error))

;;;; Spoken replies

(defun codec-test--voice-reply (shell chunks &optional stop-reason)
  "Send a voice prompt to SHELL, stream CHUNKS as the reply, end the turn.
STOP-REASON defaults to \"end_turn\".  Wait until codec handled the
end of the turn."
  (codec--handle-utterance "What happened?")
  (should codec--voice-turn)
  (codec-test--fire-reply shell chunks stop-reason)
  (should (codec-test--wait-for (lambda () (null codec--voice-turn)))))

(defun codec-test--fire-reply (shell chunks &optional stop-reason)
  "Stream CHUNKS from SHELL as agent text, then complete the turn.
STOP-REASON defaults to \"end_turn\"."
  (dolist (chunk chunks)
    (codec-test--fire shell 'agent-message-chunk `((:text-chunk . ,chunk))))
  (codec-test--fire shell 'turn-complete
                    `((:stop-reason . ,(or stop-reason "end_turn")))))

(defun codec-test--speech ()
  "Return the text the current speech process speaks."
  (car (last (process-command codec--tts-process))))

(defun codec-test--tts-runs ()
  "Return the runs of test/fake-tts.sh, each a list of its arguments."
  (with-temp-buffer
    (insert-file-contents codec-test--tts-log)
    (mapcar (lambda (line) (split-string line "|" t))
            (split-string (buffer-string) "\n" t))))

(defun codec-test--spoken-overlays (buffer)
  "Return codec's overlays in BUFFER."
  (with-current-buffer buffer
    (seq-filter (lambda (overlay) (overlay-get overlay 'codec-spoken))
                (overlays-in (point-min) (point-max)))))

(ert-deftest codec-test-extract-last-spoken-block ()
  (should (equal (codec-extract-spoken
                  "a <spoken>one</spoken> b <spoken>two</spoken> c")
                 "two"))
  (should (equal (codec-extract-spoken
                  "<spoken>one</spoken> then <spoken>unclosed")
                 "one"))
  (should-not (codec-extract-spoken "no block here"))
  (should-not (codec-extract-spoken "</spoken> backwards <spoken>"))
  (let ((codec-spoken-open "[[")
        (codec-spoken-close "]]"))
    (should (equal (codec-extract-spoken "x [[hi]] y") "hi"))))

(ert-deftest codec-test-extract-first-spoken-block ()
  (should (equal (codec-extract-spoken
                  "a <spoken>one</spoken> b <spoken>two</spoken> c" t)
                 "one"))
  (should-not (codec-extract-spoken "<spoken>unclosed so far" t))
  (should-not (codec-extract-spoken "no block here" t))
  (should-not (codec-extract-spoken "</spoken> backwards <spoken>" t)))

(ert-deftest codec-test-speakable-strips-markdown ()
  (let ((codec-spoken-max-chars 400))
    (should (equal (codec--speakable
                    (concat "\n**Done.**  Ran `make test`;\n"
                            "- see [the log](http://x/y).\n"
                            "```\ncode\n```\n# Next: _push_ it <b>now</b> "))
                   "Done. Ran make test; see the log. Next: push it now"))))

(ert-deftest codec-test-speakable-caps-length ()
  (should (equal (codec--cap "Tests pass now. Push it later today." 24)
                 "Tests pass now."))
  (should (equal (codec--cap "One two. Three four five." 20)
                 "One two. Three four"))
  (should (equal (codec--cap "short" 20) "short"))
  (should (equal (codec--cap "no limit at all" nil) "no limit at all"))
  (let ((codec-spoken-max-chars 10))
    (should (<= (length (codec--speakable "word word word word")) 10))))

(ert-deftest codec-test-bottom-reply-is-spoken-at-end ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*"))
          (codec-spoken-position 'bottom))
      (codec-test--start shell)
      ;; The tags are split across chunks, and the last block wins.
      (codec-test--voice-reply
       shell '("First <spoken>old</spoken>.  All done. <spo"
               "ken>Tests **pass**.</spo" nil "ken> trailing"))
      (should (codec--speaking-p))
      (should (equal (codec-test--speech) "Tests pass."))
      (should (codec-test--wait-for (lambda () (not (codec--speaking-p)))))
      (should (equal (codec-test--tts-runs) '(("Tests pass.")))))))

(ert-deftest codec-test-say-voice-and-rate ()
  (codec-test--with-env
    (let ((codec-say-voice "Samantha")
          (codec-say-rate 200))
      (codec-speak "Hi.")
      (should (equal (cdr (process-command codec--tts-process))
                     '("-v" "Samantha" "-r" "200" "Hi."))))))

(ert-deftest codec-test-reply-without-summary ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (codec-test--voice-reply shell '("No summary here."))
      (should (equal (codec-test--speech) "Reply ready."))
      (codec-stop-speaking)
      ;; A block with nothing speakable in it counts as none.
      (codec-test--voice-reply shell '("<spoken>```x```</spoken>"))
      (should (equal (codec-test--speech) "Reply ready."))
      (codec-stop-speaking)
      (let ((codec-no-summary-text nil))
        (codec-test--voice-reply shell '("Still none."))
        (should-not (codec--speaking-p))))))

(ert-deftest codec-test-cancelled-turn-is-not-spoken ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*"))
          (codec-spoken-position 'bottom))
      (codec-test--start shell)
      (codec-test--voice-reply shell '("<spoken>Half.</spoken>") "cancelled")
      (should-not (codec--speaking-p)))))

(ert-deftest codec-test-typed-turn-is-not-spoken ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (codec-test--fire-reply shell '("<spoken>typed</spoken>"))
      (accept-process-output nil 0.1)
      (should-not (codec--speaking-p))
      ;; After a voice turn, the next typed turn is silent too.
      (codec-test--voice-reply shell '("<spoken>voice</spoken>"))
      (should (equal (codec-test--speech) "voice"))
      (should (codec-test--wait-for (lambda () (not (codec--speaking-p)))))
      (codec-test--fire-reply shell '("<spoken>typed again</spoken>"))
      (accept-process-output nil 0.1)
      (should-not (codec--speaking-p))
      (should (equal (codec-test--tts-runs) '(("voice")))))))

(ert-deftest codec-test-old-target-reply-is-not-spoken ()
  (codec-test--with-env
    (let ((a (codec-test--shell "*agent-shell a*"))
          (b (codec-test--shell "*agent-shell b*")))
      (codec-test--start a)
      (codec--handle-utterance "hello")
      (codec-set-target b)
      (should-not codec--voice-turn)
      (codec-test--fire-reply b '("<spoken>b</spoken>"))
      (accept-process-output nil 0.1)
      (should-not (codec--speaking-p)))))

(ert-deftest codec-test-mutes-while-speaking ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (setq codec-test--commands nil)
      (codec-test--voice-reply shell '("<spoken>Hi.</spoken>"))
      (should (equal codec-test--commands '("mute")))
      (should (eq (codec-state) 'speaking))
      (should (equal (substring-no-properties (codec--mode-line))
                     " Codec:speaking"))
      (should (codec-test--wait-for (lambda () (not (codec--speaking-p)))))
      (should (equal codec-test--commands '("unmute" "mute")))
      (should (eq (codec-state) 'listening)))))

(ert-deftest codec-test-failed-speech-unmutes ()
  (codec-test--with-env
    (codec-test--start (codec-test--shell "*agent-shell a*"))
    (setenv "CODEC_FAKE_TTS_EXIT" "1")
    (setq codec-test--commands nil)
    (codec-speak "Hi.")
    (should (codec-test--wait-for (lambda () (not (codec--speaking-p)))))
    (should (equal codec-test--commands '("unmute" "mute")))
    (with-current-buffer codec-log-buffer
      (should (string-match-p "fake-tts.sh failed: 1" (buffer-string))))
    ;; A program that does not exist mutes nothing.
    (setq codec-test--commands nil)
    (let ((codec-say-program "/nonexistent/say"))
      (codec-speak "Hi."))
    (should-not (codec--speaking-p))
    (should-not codec-test--commands)
    (should (string-match-p "cannot speak" (car codec-test--messages)))))

(ert-deftest codec-test-stop-speaking-barges-in ()
  (codec-test--with-env
    (codec-test--start (codec-test--shell "*agent-shell a*"))
    (setenv "CODEC_FAKE_TTS_SLEEP" "10")
    (setq codec-test--commands nil)
    (codec-speak "A long summary.")
    (let ((process codec--tts-process))
      (should (process-live-p process))
      (codec-stop-speaking)
      (should-not (process-live-p process))
      (should-not (codec--speaking-p))
      (should (equal codec-test--commands '("unmute" "mute")))
      (should (eq (codec-state) 'listening))
      ;; The sentinel of the killed process unmutes nothing more.
      (accept-process-output nil 0.1)
      (should (equal codec-test--commands '("unmute" "mute"))))))

(ert-deftest codec-test-manual-mute-survives-speech ()
  (codec-test--with-env
    (codec-test--start (codec-test--shell "*agent-shell a*"))
    (setenv "CODEC_FAKE_TTS_SLEEP" "10")
    (codec-speak "One.")
    (codec-mute)
    (setq codec-test--commands nil)
    (codec-stop-speaking)
    (should-not (member "unmute" codec-test--commands))
    (should (eq (codec-state) 'muted))
    ;; Nor does speech that ends by itself unmute.
    (setenv "CODEC_FAKE_TTS_SLEEP" "0.1")
    (codec-speak "Two.")
    (should (codec-test--wait-for (lambda () (not (codec--speaking-p)))))
    (should-not (member "unmute" codec-test--commands))
    (should (eq (codec-state) 'muted))
    ;; `codec-unmute' while codec speaks waits for the speech to end.
    (setenv "CODEC_FAKE_TTS_SLEEP" "0.3")
    (codec-speak "Three.")
    (setq codec-test--commands nil)
    (codec-unmute)
    (should (equal codec-test--commands '("mute")))
    (should (codec-test--wait-for (lambda () (not (codec--speaking-p)))))
    (should (equal codec-test--commands '("unmute" "mute")))
    (should (eq (codec-state) 'listening))))

(ert-deftest codec-test-new-speech-interrupts-old ()
  (codec-test--with-env
    (codec-test--start (codec-test--shell "*agent-shell a*"))
    (setenv "CODEC_FAKE_TTS_SLEEP" "10")
    (setq codec-test--commands nil)
    (codec-speak "First.")
    (let ((first codec--tts-process))
      (codec-speak "Second.")
      (should-not (process-live-p first))
      (should (process-live-p codec--tts-process))
      (should (equal (codec-test--speech) "Second."))
      (accept-process-output nil 0.1)
      ;; No unmute between the two.
      (should (equal codec-test--commands '("mute")))
      (should (eq (codec-state) 'speaking)))))

(ert-deftest codec-test-mode-off-stops-speech ()
  (codec-test--with-env
    (codec-test--start (codec-test--shell "*agent-shell a*"))
    (setenv "CODEC_FAKE_TTS_SLEEP" "10")
    (codec-speak "Hi.")
    (let ((process codec--tts-process))
      (setq codec-test--commands nil)
      (codec-mode -1)
      (should-not (process-live-p process))
      (accept-process-output nil 0.1)
      (should-not codec-test--commands)
      (should-not codec--speech-muted))))

(ert-deftest codec-test-pedal ()
  (codec-test--with-env
    (with-current-buffer (codec-test--shell "*agent-shell a*")
      (codec-pedal))
    (should codec-mode)
    (should (codec-test--wait-for (lambda () codec--ready)))
    (setenv "CODEC_FAKE_TTS_SLEEP" "10")
    (codec-speak "Hi.")
    ;; Speaking: barge in, and stay on.
    (codec-pedal)
    (should codec-mode)
    (should-not (codec--speaking-p))
    (should (eq (codec-state) 'listening))
    ;; Not speaking: toggle.
    (codec-pedal)
    (should-not codec-mode)))

(ert-deftest codec-test-spoken-block-gets-overlay ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*"))
          (reply "Reply. <spoken>Done.</spoken>\n"))
      (codec-test--start shell)
      (with-current-buffer shell
        (insert "Prompt: end with <spoken>a summary</spoken>.\n"))
      (codec--handle-utterance "hi")
      (codec-test--fire shell 'agent-message-chunk `((:text-chunk . ,reply)))
      (with-current-buffer shell (insert reply))
      (let ((text (with-current-buffer shell (buffer-string))))
        (codec-test--fire shell 'turn-complete '((:stop-reason . "end_turn")))
        (should (codec-test--wait-for (lambda () (null codec--voice-turn))))
        (let ((overlays (codec-test--spoken-overlays shell)))
          (should (= (length overlays) 1))
          (with-current-buffer shell
            (should (equal (buffer-substring (overlay-start (car overlays))
                                             (overlay-end (car overlays)))
                           "<spoken>Done.</spoken>"))
            ;; The text is unchanged.
            (should (equal (buffer-string) text)))
          (should (eq (overlay-get (car overlays) 'face) 'codec-spoken-face))
          (should-not (overlay-get (car overlays) 'invisible))))
      ;; A reply without a block marks nothing, not even the prompt.
      (codec-stop-speaking)
      (with-current-buffer shell (delete-all-overlays))
      (codec--handle-utterance "hi")
      (codec-test--fire shell 'agent-message-chunk '((:text-chunk . "None.")))
      (with-current-buffer shell (insert "None.\n"))
      (codec-test--fire shell 'turn-complete '((:stop-reason . "end_turn")))
      (should (codec-test--wait-for (lambda () (null codec--voice-turn))))
      (should-not (codec-test--spoken-overlays shell)))))

(ert-deftest codec-test-hide-spoken ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*"))
          (codec-hide-spoken t))
      (codec-test--start shell)
      (codec--handle-utterance "hi")
      (codec-test--fire shell 'agent-message-chunk
                        '((:text-chunk . "<spoken>Hidden.</spoken>")))
      (with-current-buffer shell (insert "<spoken>Hidden.</spoken>"))
      (codec-test--fire shell 'turn-complete '((:stop-reason . "end_turn")))
      (should (codec-test--wait-for (lambda () (null codec--voice-turn))))
      (let ((overlays (codec-test--spoken-overlays shell)))
        (should (= (length overlays) 1))
        (should (overlay-get (car overlays) 'invisible))))))

;;;; Summary at the top

(ert-deftest codec-test-top-summary-is-spoken-early ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (codec--handle-utterance "What happened?")
      (setq codec-test--busy t)
      ;; Both tags are split across chunks.
      (dolist (chunk '("<spo" "ken>Tests **pass**." nil "</spo"))
        (codec-test--fire shell 'agent-message-chunk `((:text-chunk . ,chunk)))
        (should-not (codec--speaking-p)))
      (codec-test--fire shell 'agent-message-chunk '((:text-chunk . "ken>\nMore")))
      ;; Spoken at once, while the agent still writes.
      (should (codec--speaking-p))
      (should (equal (codec-test--speech) "Tests pass."))
      (should codec--voice-turn)
      (should (codec-test--wait-for (lambda () (not (codec--speaking-p)))))
      (should (equal (codec-test--tts-runs) '(("Tests pass.")))))))

(ert-deftest codec-test-top-summary-is-spoken-once ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (setenv "CODEC_FAKE_TTS_SLEEP" "10")
      (codec--handle-utterance "What happened?")
      (codec-test--fire shell 'agent-message-chunk
                        '((:text-chunk . "<spoken>First.</spoken> Body. ")))
      (let ((process codec--tts-process))
        (should (equal (codec-test--speech) "First."))
        ;; A later block in the same turn and the end of the turn neither
        ;; kill nor restart the speech.
        (codec-test--fire-reply shell '("<spoken>Second.</spoken> end"))
        (should (codec-test--wait-for (lambda () (null codec--voice-turn))))
        (accept-process-output nil 0.1)
        (should (eq codec--tts-process process))
        (should (process-live-p process))
        (should (equal (codec-test--speech) "First."))))))

(ert-deftest codec-test-top-without-summary-falls-back ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (codec--handle-utterance "What happened?")
      (codec-test--fire shell 'agent-message-chunk
                        '((:text-chunk . "No summary here.")))
      (should-not (codec--speaking-p))
      (codec-test--fire shell 'turn-complete '((:stop-reason . "end_turn")))
      (should (codec-test--wait-for (lambda () (null codec--voice-turn))))
      (should (equal (codec-test--speech) "Reply ready."))
      (codec-stop-speaking)
      ;; A first block with nothing speakable counts as none, and a later
      ;; block does not stand in for it.
      (codec--handle-utterance "Again?")
      (codec-test--fire shell 'agent-message-chunk
                        '((:text-chunk . "<spoken>```x```</spoken> b ")))
      (codec-test--fire shell 'agent-message-chunk
                        '((:text-chunk . "<spoken>Later.</spoken>")))
      (should-not (codec--speaking-p))
      (codec-test--fire shell 'turn-complete '((:stop-reason . "end_turn")))
      (should (codec-test--wait-for (lambda () (null codec--voice-turn))))
      (should (equal (codec-test--speech) "Reply ready.")))))

(ert-deftest codec-test-bottom-summary-waits-for-turn-end ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*"))
          (codec-spoken-position 'bottom))
      (codec-test--start shell)
      (codec--handle-utterance "What happened?")
      (codec-test--fire shell 'agent-message-chunk
                        '((:text-chunk . "<spoken>Early.</spoken> body ")))
      (should-not (codec--speaking-p))
      (codec-test--fire shell 'agent-message-chunk
                        '((:text-chunk . "<spoken>Late.</spoken>")))
      (should-not (codec--speaking-p))
      (codec-test--fire shell 'turn-complete '((:stop-reason . "end_turn")))
      (should (codec-test--wait-for (lambda () (null codec--voice-turn))))
      (should (equal (codec-test--speech) "Late.")))))

(ert-deftest codec-test-top-block-gets-overlay ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*"))
          (reply "<spoken>Done.</spoken>\nDetails.  <spoken>Not this.</spoken>\n"))
      (codec-test--start shell)
      (with-current-buffer shell
        (insert "Prompt: begin with <spoken>a summary</spoken>.\n"))
      (codec--handle-utterance "hi")
      (codec-test--fire shell 'agent-message-chunk `((:text-chunk . ,reply)))
      (with-current-buffer shell (insert reply))
      (codec-test--fire shell 'turn-complete '((:stop-reason . "end_turn")))
      (should (codec-test--wait-for (lambda () (null codec--voice-turn))))
      (let ((overlays (codec-test--spoken-overlays shell)))
        (should (= (length overlays) 1))
        (with-current-buffer shell
          (should (equal (buffer-substring (overlay-start (car overlays))
                                           (overlay-end (car overlays)))
                         "<spoken>Done.</spoken>")))
        (should (eq (overlay-get (car overlays) 'face) 'codec-spoken-face))))))

(ert-deftest codec-test-unmute-while-agent-busy-queues ()
  (codec-test--with-env
    (let ((shell (codec-test--shell "*agent-shell a*")))
      (codec-test--start shell)
      (codec--handle-utterance "What happened?")
      (setq codec-test--busy t
            codec-test--sent nil
            codec-test--commands nil)
      (codec-test--fire shell 'agent-message-chunk
                        '((:text-chunk . "<spoken>Done.</spoken> More")))
      (should (equal codec-test--commands '("mute")))
      ;; The speech ends before the turn: the listener is on again.
      (should (codec-test--wait-for (lambda () (not (codec--speaking-p)))))
      (should (equal codec-test--commands '("unmute" "mute")))
      (should (eq (codec-state) 'listening))
      ;; An utterance now waits for the turn to end.
      (codec--handle-utterance "Next step.")
      (should (equal codec--queue '("Next step.")))
      (should-not codec-test--sent)
      (setq codec-test--busy nil)
      (codec-test--fire shell 'turn-complete '((:stop-reason . "end_turn")))
      (should (codec-test--wait-for (lambda () codec-test--sent)))
      (should (equal (codec-test--sent-texts)
                     (list (codec-wrap-transcript "Next step."))))
      (should-not codec--queue)
      ;; The end of the turn spoke nothing more.
      (should-not (codec--speaking-p))
      (should (equal (codec-test--tts-runs) '(("Done.")))))))

(ert-deftest codec-test-piper-backend ()
  (codec-test--with-env
    (let* ((fake (expand-file-name "fake-tts.sh" codec-test--directory))
           (codec-tts-backend 'piper)
           (codec-piper-program fake)
           (codec-piper-model "/tmp/voice.onnx")
           (codec-piper-extra-args '("--length_scale" "0.9"))
           (codec-audio-player (list fake "-q")))
      (setenv "CODEC_FAKE_TTS_SLEEP" "0.5")
      (codec-speak "Hello there.")
      (should (codec--speaking-p))
      ;; Piper is done and the player plays its file.
      (should (codec-test--wait-for
               (lambda ()
                 (and codec--tts-process
                      (not (process-get codec--tts-process 'codec-then-play))))))
      (let ((wav (car (last (process-command codec--tts-process)))))
        (should (equal (with-temp-buffer
                         (insert-file-contents wav)
                         (buffer-string))
                       "Hello there.\n"))
        (should (codec-test--wait-for (lambda () (not (codec--speaking-p)))))
        (should (equal (codec-test--tts-runs)
                       `(("--model" "/tmp/voice.onnx" "--output_file" ,wav
                          "--length_scale" "0.9")
                         ("-q" ,wav))))
        (should-not (file-exists-p wav)))
      ;; Without a model, it tells the user.
      (let ((codec-piper-model nil))
        (codec-speak "Hi."))
      (should-not (codec--speaking-p))
      (should (string-match-p "codec-piper-model" (car codec-test--messages))))))

(ert-deftest codec-test-stop-piper-deletes-file ()
  (codec-test--with-env
    (let* ((fake (expand-file-name "fake-tts.sh" codec-test--directory))
           (codec-tts-backend 'piper)
           (codec-piper-program fake)
           (codec-piper-model "/tmp/voice.onnx")
           (codec-audio-player (list fake)))
      (setenv "CODEC_FAKE_TTS_SLEEP" "10")
      (codec-speak "Hello.")
      (let ((wav (process-get codec--tts-process 'codec-wav)))
        (should (file-exists-p wav))
        (codec-stop-speaking)
        (should-not (file-exists-p wav))))))

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
