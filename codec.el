;;; codec.el --- Hands-free voice input for agent-shell -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; Maintainer: Chaz Straney <chaz.straney@gmail.com>
;; URL: https://github.com/chazu/codec.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.76.1"))
;; Keywords: convenience, multimedia
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Talk to an agent-shell agent without touching the keyboard.
;;
;; `codec-mode' is a global minor mode.  While it is on, a local Python
;; listener (Silero VAD and faster-whisper, in the listener/ directory)
;; captures the microphone.  A pause of `codec-silence-ms' ends an
;; utterance; the listener transcribes it and codec sends the text to
;; the target agent-shell buffer as a new prompt.  Nothing leaves the
;; machine.
;;
;; Each voice prompt gets `codec-voice-preamble', which asks the agent
;; to begin its reply with a short summary between `codec-spoken-open'
;; and `codec-spoken-close'.  Typed prompts are left alone.  As soon as
;; the summary of a reply to a voice prompt has streamed in, codec
;; speaks it with `codec-tts-backend' (macOS say, or Piper) and mutes
;; the listener while it speaks.  Set `codec-spoken-position' to bottom
;; to ask for the summary at the end and hear it when the turn ends.
;;
;; Suggested binding, for a foot pedal that sends S-<f12>:
;;
;;   (keymap-global-set "S-<f12>" #'codec-pedal)
;;
;; The pedal stops the speech if codec speaks, and otherwise toggles
;; `codec-mode'.
;;
;; See README.md for setup, the microphone permission on macOS, and
;; the listener protocol.

;;; Code:

(require 'format-spec)
(require 'seq)
(require 'subr-x)

(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell-subscribe-to "agent-shell")
(declare-function agent-shell-unsubscribe "agent-shell")
(declare-function shell-maker-busy "shell-maker" ())
(defvar agent-shell-prefer-viewport-interaction)

;;;; Customization

(defgroup codec nil
  "Hands-free voice input for agent-shell."
  :group 'convenience
  :prefix "codec-")

(defcustom codec-uv-program "uv"
  "The uv program that runs the listener."
  :type 'string)

(defcustom codec-listener-directory nil
  "The directory with codec_listener.py and its pyproject.toml.
nil means the listener/ directory next to the real file of codec.el.
uv keeps the listener's virtual environment in .venv inside it."
  :type '(choice (const :tag "Next to codec.el" nil) directory))

(defcustom codec-listener-command nil
  "The program and arguments that start the listener, or nil.
nil means run listener/codec_listener.py with `codec-uv-program'.
The arguments made from the options below are appended either way."
  :type '(choice (const :tag "Run with uv" nil) (repeat string)))

(defcustom codec-model "small.en"
  "The Whisper model the listener uses.
A faster-whisper model name such as \"base.en\", \"small.en\" or
\"medium.en\", or the path of a converted model.  Smaller models are
faster and less accurate.  The model is downloaded on first use; see
`codec-download-model'."
  :type 'string)

(defcustom codec-device 'auto
  "The device that runs the Whisper model.
auto means the Apple GPU (mps) on Apple Silicon, and CTranslate2's
own choice elsewhere.  If the model fails to load on mps, the
listener uses the CPU."
  :type '(choice (const :tag "Automatic" auto)
                 (const :tag "Apple GPU" mps)
                 (const :tag "CPU" cpu)
                 (string :tag "Other CTranslate2 device")))

(defcustom codec-compute-type 'auto
  "The CTranslate2 compute type of the Whisper model.
auto means int8_float16 on mps and int8 on the CPU."
  :type '(choice (const :tag "Automatic" auto)
                 (string :tag "Compute type")))

(defcustom codec-silence-ms 900
  "Milliseconds of silence that end an utterance."
  :type 'natnum)

(defcustom codec-drop-phrases nil
  "Transcripts the listener drops, as well as its built-in list.
The built-in list holds the phrases Whisper invents on silence, such
as \"you\" and \"Thank you.\".  Case and punctuation do not matter."
  :type '(repeat string))

(defcustom codec-listener-extra-args nil
  "More arguments for the listener, such as (\"--beam-size\" \"1\").
Run the listener with --help for the full list."
  :type '(repeat string))

(defcustom codec-spoken-open "<spoken>"
  "The tag that opens the spoken summary in a reply to a voice prompt."
  :type 'string)

(defcustom codec-spoken-close "</spoken>"
  "The tag that closes the spoken summary in a reply to a voice prompt."
  :type 'string)

(defcustom codec-spoken-position 'top
  "Where the agent puts the spoken summary in its reply.
top asks for the summary first, and codec speaks it as soon as its
close tag arrives, while the agent writes the rest.  bottom asks for
it last, and codec speaks it when the turn completes."
  :type '(choice (const :tag "At the start of the reply" top)
                 (const :tag "At the end of the reply" bottom)))

(defconst codec-voice-preambles
  `((top
     . ,(concat "[voice] The user is speaking to you hands-free and will "
                "hear only a short spoken summary.  Begin your reply with "
                "%oone or two plain, speakable sentences: the result and "
                "the one thing the user should do next%c.  Then answer "
                "normally in full.  No code, paths or markdown inside %o.  "
                "The transcript below may have speech-recognition errors."))
    (bottom
     . ,(concat "[voice] The user is speaking to you hands-free and will "
                "hear only a short spoken summary.  Answer normally in "
                "full.  Then end your reply with %oone or two plain, "
                "speakable sentences: the result and the one thing the "
                "user should do next%c.  No code, paths or markdown inside "
                "%o.  The transcript below may have speech-recognition "
                "errors.")))
  "The built-in voice preamble for each `codec-spoken-position'.")

(defcustom codec-voice-preamble nil
  "Instructions added to each voice prompt, and to no typed prompt.
nil means the text in `codec-voice-preambles' for
`codec-spoken-position'.  In a string, %o stands for
`codec-spoken-open' and %c for `codec-spoken-close'; write %% for a
literal %.  An empty string adds nothing."
  :type '(choice (const :tag "Built-in text for `codec-spoken-position'" nil)
                 string))

(defcustom codec-preamble-position 'prepend
  "Where `codec-voice-preamble' goes relative to the transcript."
  :type '(choice (const :tag "Before the transcript" prepend)
                 (const :tag "After the transcript" append)))

(defcustom codec-cancel-phrases '("scratch that" "cancel")
  "Utterances that send nothing and discard queued utterances.
An utterance matches when it equals a phrase, ignoring case and
punctuation."
  :type '(repeat string))

(defcustom codec-mode-line-states
  '((off . "")
    (starting . " Codec:…")
    (listening . " Codec:on")
    (muted . " Codec:muted")
    (speaking . " Codec:speaking")
    (error . " Codec:err"))
  "Mode line text for each state of `codec-mode'."
  :type '(alist :key-type symbol :value-type string))

(defcustom codec-shutdown-timeout 2
  "Seconds to wait for the listener to quit before it is killed."
  :type 'number)

(defcustom codec-after-send-functions nil
  "Functions called after a voice prompt is sent.
Each is called with the agent-shell buffer and the transcript, without
the preamble."
  :type 'hook)

(defconst codec-log-buffer "*codec-listener-log*"
  "The buffer that gets the listener's stderr and codec's own log.")

;;;; State

(defvar codec--process nil "The listener process.")
(defvar codec--stderr-process nil "The pipe that carries the listener's stderr.")
(defvar codec--ready nil "Non-nil once the listener said it is ready.")
(defvar codec--device nil
  "The device and compute type of the listener, such as \"mps, float16\".")
(defvar codec--muted nil "Non-nil while voice input is muted.")
(defvar codec--muted-for-target nil
  "Non-nil if codec muted itself because it had no live target.")
(defvar codec--error nil "The message of the error that stopped the listener.")
(defvar codec--last-error nil "The message of the listener's last error event.")
(defvar codec--target nil "The agent-shell buffer that gets voice prompts.")
(defvar codec--subscriptions nil
  "The agent-shell event subscriptions, as (BUFFER . TOKEN) pairs.")
(defvar codec--queue nil
  "Transcripts that wait for the target agent to finish its turn.")

;;;; Mode

;;;###autoload
(define-minor-mode codec-mode
  "Toggle hands-free voice input for agent-shell.

When on, a local listener captures the microphone and each utterance
is sent to the target agent-shell buffer as a prompt, with
`codec-voice-preamble'.  The target is the agent-shell buffer that is
current, or else the one selected most recently; change it with
`codec-set-target'.  While the agent is in a turn, utterances wait
and go out when the turn completes.  Say a phrase in
`codec-cancel-phrases' to discard them.

When the agent replies to a voice prompt, codec speaks the summary
in the reply with `codec-tts-backend', and mutes the listener while
it speaks.  Typed prompts get no speech.

\\[codec-mute] and \\[codec-unmute] pause and resume listening.
\\[codec-stop-speaking] stops the speech at once, and \\[codec-pedal]
does that or toggles the mode.

For a foot pedal that sends S-<f12>:

  (keymap-global-set \"S-<f12>\" #\\='codec-pedal)"
  :global t
  :lighter (:eval (codec--mode-line))
  (if codec-mode
      (codec--start)
    (codec--stop)))

(defun codec-state ()
  "Return the state of `codec-mode'.
One of the symbols off, starting, listening, muted, speaking or error."
  (cond ((not codec-mode) 'off)
        (codec--error 'error)
        ((not codec--ready) 'starting)
        ((codec--speaking-p) 'speaking)
        (codec--muted 'muted)
        (t 'listening)))

(defun codec--mode-line ()
  "Return the mode line text for the state of `codec-mode'."
  (let ((state (codec-state)))
    (propertize (or (alist-get state codec-mode-line-states) "")
                'face (pcase state
                        ('error 'error)
                        ('listening 'success)
                        (_ nil))
                'help-echo (cond (codec--error
                                  (format "codec: %s" codec--error))
                                 (codec--device
                                  (format "codec: %s on %s" state codec--device))
                                 (t (format "codec: %s" state))))))

(defun codec--start ()
  "Start the listener and choose the target."
  (codec--stop)
  (codec--set-target (codec--pick-target))
  (condition-case err
      (setq codec--process (codec--make-process))
    (error
     (setq codec--error (error-message-string err))
     (message "codec: cannot start the listener: %s" codec--error)))
  (unless codec--target
    (codec--mute-for-target
     "codec: no agent-shell buffer; muted until `codec-set-target'"))
  (force-mode-line-update t))

(defun codec--stop ()
  "Stop the listener and the speech, and forget the target and the queue."
  (codec--reset-speech)
  (codec--drop-voice-turn)
  (codec--unsubscribe)
  (codec--stop-process)
  (setq codec--target nil
        codec--queue nil
        codec--ready nil
        codec--device nil
        codec--muted nil
        codec--muted-for-target nil
        codec--error nil
        codec--last-error nil)
  (force-mode-line-update t))

;;;; Commands

(defun codec-mute ()
  "Stop sending utterances until `codec-unmute'.
The listener discards audio while muted."
  (interactive)
  (unless codec-mode
    (user-error "`codec-mode' is off"))
  (codec--set-muted t)
  (setq codec--muted-for-target nil)
  (message "codec: muted"))

(defun codec-unmute ()
  "Resume sending utterances after `codec-mute'."
  (interactive)
  (unless codec-mode
    (user-error "`codec-mode' is off"))
  (unless (codec--target-live-p)
    (user-error "No agent-shell target; use `codec-set-target'"))
  (codec--set-muted nil)
  (setq codec--muted-for-target nil)
  (message "codec: listening"))

(defun codec-set-target (buffer)
  "Send voice prompts to the agent-shell BUFFER.
Interactively, read the buffer, with the current one as default if it
is an agent-shell buffer.  If codec muted itself because its target
was gone, unmute it."
  (interactive (list (codec--read-target)))
  (unless (codec--agent-shell-buffer-p buffer)
    (user-error "%s is not an agent-shell buffer" buffer))
  (codec--set-target buffer)
  (when (and codec--muted codec--muted-for-target)
    (setq codec--muted-for-target nil)
    (codec--set-muted nil))
  (message "codec: sending to %s" (buffer-name buffer)))

(defun codec-download-model ()
  "Install the listener's Python packages and download `codec-model'.
Runs in a compilation buffer.  Needs network access once; after that
the listener works offline."
  (interactive)
  (let ((default-directory (codec--listener-directory)))
    (compile (mapconcat #'shell-quote-argument
                        (append (codec--listener-base-command)
                                (codec--listener-arguments)
                                '("--download-only"))
                        " "))))

;;;; Target

(defun codec--agent-shell-buffer-p (buffer)
  "Return non-nil if BUFFER is a live agent-shell buffer."
  (and (buffer-live-p buffer)
       (provided-mode-derived-p (buffer-local-value 'major-mode buffer)
                                'agent-shell-mode)))

(defun codec--target-live-p ()
  "Return non-nil if the target is a live agent-shell buffer."
  (codec--agent-shell-buffer-p codec--target))

(defun codec--pick-target ()
  "Return the current agent-shell buffer, or the one selected last."
  (seq-find #'codec--agent-shell-buffer-p
            (cons (current-buffer) (buffer-list))))

(defun codec--read-target ()
  "Read an agent-shell buffer in the minibuffer."
  (let ((default (codec--pick-target)))
    (unless default
      (user-error "There is no agent-shell buffer"))
    (get-buffer
     (read-buffer "codec target: " default t
                  (lambda (candidate)
                    (codec--agent-shell-buffer-p
                     (get-buffer (if (consp candidate)
                                     (car candidate)
                                   candidate))))))))

(defun codec--set-target (buffer)
  "Make BUFFER the target and subscribe to its events.
BUFFER nil means no target."
  (codec--unsubscribe)
  (codec--drop-voice-turn)
  (setq codec--target buffer)
  (when buffer
    ;; Not from inside agent-shell's own handling.
    (codec--subscribe buffer 'turn-complete
                      (lambda (event)
                        (run-at-time 0 nil #'codec--turn-complete buffer
                                     (alist-get :data event))))
    (codec--subscribe buffer 'prompt-ready
                      (lambda (_event)
                        (run-at-time 0 nil #'codec--flush)))
    (codec--subscribe buffer 'agent-message-chunk
                      (lambda (event)
                        (codec--add-chunk
                         buffer (alist-get :text-chunk
                                           (alist-get :data event)))))
    (codec--subscribe buffer 'clean-up
                      (lambda (_event)
                        (run-at-time 0 nil #'codec--check-target)))))

(defun codec--subscribe (buffer event function)
  "Call FUNCTION on each EVENT in agent-shell BUFFER while it is the target."
  (push (cons buffer
              (agent-shell-subscribe-to
               :shell-buffer buffer :event event
               :on-event (lambda (data)
                           (when (eq buffer codec--target)
                             (funcall function data)))))
        codec--subscriptions))

(defun codec--unsubscribe ()
  "Remove all of codec's agent-shell event subscriptions."
  (pcase-dolist (`(,buffer . ,token) codec--subscriptions)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ignore-errors (agent-shell-unsubscribe :subscription token)))))
  (setq codec--subscriptions nil))

(defun codec--check-target ()
  "Mute and tell the user if the target is gone."
  (when (and codec-mode codec--target (not (codec--target-live-p)))
    (codec--unsubscribe)
    (setq codec--target nil)
    (when codec--queue
      (codec--log "discarded %d queued utterance(s)" (length codec--queue))
      (setq codec--queue nil))
    (codec--mute-for-target
     "codec: the target agent-shell is gone; muted until `codec-set-target'")))

(defun codec--mute-for-target (message)
  "Mute because there is no live target, and show MESSAGE."
  (codec--set-muted t)
  (setq codec--muted-for-target t)
  (message "%s" message))

;;;; Sending

(defun codec-wrap-transcript (transcript)
  "Return TRANSCRIPT with `codec-voice-preamble' added."
  (let ((preamble (string-trim
                   (format-spec (or codec-voice-preamble
                                    (alist-get codec-spoken-position
                                               codec-voice-preambles))
                                `((?o . ,codec-spoken-open)
                                  (?c . ,codec-spoken-close))))))
    (cond ((string-empty-p preamble) transcript)
          ((eq codec-preamble-position 'append)
           (concat transcript "\n\n" preamble))
          (t (concat preamble "\n\n" transcript)))))

(defun codec--normalize (text)
  "Return TEXT lowercased, without punctuation, single-spaced."
  (string-join (split-string
                (downcase (replace-regexp-in-string "[^[:alnum:]']+" " " text))
                nil t)
               " "))

(defun codec--cancel-phrase-p (text)
  "Return non-nil if TEXT is one of `codec-cancel-phrases'."
  (member (codec--normalize text)
          (mapcar #'codec--normalize codec-cancel-phrases)))

(defun codec--busy-p (buffer)
  "Return non-nil if the agent in BUFFER is in a turn."
  (with-current-buffer buffer
    (and (fboundp 'shell-maker-busy)
         (ignore-errors (shell-maker-busy)))))

(defun codec--handle-utterance (text)
  "Send TEXT to the target, queue it, or discard it."
  (let ((text (string-trim (or text ""))))
    (cond
     ((string-empty-p text))
     (codec--muted
      (codec--log "dropped while muted: %s" text))
     ((codec--cancel-phrase-p text)
      (setq codec--queue nil)
      (message "codec: discarded"))
     ((not (codec--target-live-p))
      (codec--log "dropped, no target: %s" text)
      (codec--check-target))
     (t
      (setq codec--queue (append codec--queue (list text)))
      (codec--flush)
      (when codec--queue
        (message "codec: agent busy; queued %d utterance(s)"
                 (length codec--queue)))))))

(defun codec--flush ()
  "Send the queued transcripts to the target if it is not busy.
They go as one voice prompt."
  (cond
   ((null codec--queue))
   ((not (codec--target-live-p)) (codec--check-target))
   ((codec--busy-p codec--target))
   (t
    (let ((transcript (string-join codec--queue "\n\n"))
          (buffer codec--target))
      (setq codec--queue nil)
      (with-current-buffer buffer
        (let ((agent-shell-prefer-viewport-interaction nil))
          (agent-shell-insert :text (codec-wrap-transcript transcript)
                              :submit t :no-focus t :shell-buffer buffer)))
      (codec--begin-voice-turn buffer)
      (run-hook-with-args 'codec-after-send-functions buffer transcript)))))

;;;; Spoken replies

(defface codec-spoken-face
  '((t :inherit shadow))
  "Face of the spoken summary in an agent-shell buffer.")

(defcustom codec-hide-spoken nil
  "Non-nil means make the spoken summary in the buffer invisible.
nil shows it with `codec-spoken-face'.  The buffer text does not
change either way."
  :type 'boolean)

(defcustom codec-spoken-max-chars 400
  "The longest summary codec speaks, in characters.
A longer summary is cut at a sentence end or a word.  nil means no
limit."
  :type '(choice (const :tag "No limit" nil) natnum))

(defcustom codec-no-summary-text "Reply ready."
  "What codec says when a reply to a voice prompt has no summary.
nil means say nothing."
  :type '(choice (const :tag "Nothing" nil) string))

(defvar codec--voice-turn nil
  "The reply to the last voice prompt, while the agent writes it.
A plist with :buffer, the agent-shell buffer; :chunks, the text
chunks so far, newest first; :start, a marker at the start of the
reply, or nil before the first chunk; :position, the value of
`codec-spoken-position' when the prompt was sent; and :spoken,
non-nil once codec started to speak the summary before the end of
the turn.")

(defun codec--begin-voice-turn (buffer)
  "Start to collect the reply in BUFFER to a voice prompt."
  (codec--drop-voice-turn)
  (setq codec--voice-turn (list :buffer buffer :chunks nil :start nil
                                :position codec-spoken-position
                                :spoken nil)))

(defun codec--drop-voice-turn ()
  "Forget the voice turn in progress, if any."
  (when-let* ((start (plist-get codec--voice-turn :start)))
    (set-marker start nil))
  (setq codec--voice-turn nil))

(defun codec--add-chunk (buffer chunk)
  "Add the text CHUNK of the reply in BUFFER if it is a voice turn.
CHUNK is nil for a block that is not text."
  (let ((turn codec--voice-turn))
    (when (and turn (eq buffer (plist-get turn :buffer)) (stringp chunk))
      (unless (plist-get turn :start)
        (setq turn (plist-put turn :start (with-current-buffer buffer
                                            (copy-marker (point-max))))))
      (setq codec--voice-turn
            (plist-put turn :chunks (cons chunk (plist-get turn :chunks))))
      (codec--maybe-speak-early chunk))))

(defun codec--maybe-speak-early (chunk)
  "Speak the first summary of the voice turn if CHUNK completed it.
Only when the summary goes at the top; see `codec-spoken-position'.
A summary with nothing speakable in it is left for the end of the
turn, which then says `codec-no-summary-text'."
  (let ((turn codec--voice-turn)
        (close codec-spoken-close))
    (when (and codec-mode
               (eq (plist-get turn :position) 'top)
               (not (plist-get turn :spoken))
               (not (string-empty-p close))
               ;; The close tag can only end in a chunk with its last char.
               (string-search (substring close -1) chunk))
      (when-let* ((spoken (codec-extract-spoken
                           (apply #'concat (reverse (plist-get turn :chunks)))
                           t))
                  (speech (codec--speakable spoken))
                  ((not (string-empty-p speech))))
        (setq codec--voice-turn (plist-put turn :spoken t))
        (codec-speak speech)))))

(defun codec--turn-complete (buffer data)
  "Speak the reply in BUFFER if it was a voice turn, then send the queue.
DATA is the data of agent-shell's turn-complete event."
  (when codec-mode
    (codec--finish-voice-turn buffer data))
  (codec--flush))

(defun codec--finish-voice-turn (buffer data)
  "Speak the summary of the voice turn in BUFFER and mark it in BUFFER.
DATA is the data of the turn-complete event.  Speak nothing if the
turn was cancelled, or if codec already speaks the summary from the
top of the reply."
  (let ((turn codec--voice-turn))
    (when (and turn (eq buffer (plist-get turn :buffer)))
      (let* ((first (eq (plist-get turn :position) 'top))
             (text (apply #'concat (reverse (plist-get turn :chunks))))
             (spoken (codec-extract-spoken text first))
             (speech (and spoken (codec--speakable spoken)))
             (start (plist-get turn :start)))
        (when (and spoken start (buffer-live-p buffer))
          (codec--mark-spoken buffer start first))
        (codec--drop-voice-turn)
        (unless (or (plist-get turn :spoken)
                    (equal (alist-get :stop-reason data) "cancelled"))
          (cond ((and speech (not (string-empty-p speech)))
                 (codec-speak speech))
                (codec-no-summary-text
                 (codec-speak codec-no-summary-text))))))))

(defun codec--first-index (needle haystack &optional start)
  "Return where the first NEEDLE in HAYSTACK at or after START starts.
Return nil if there is none."
  (unless (string-empty-p needle)
    (string-search needle haystack (or start 0))))

(defun codec--last-index (needle haystack &optional end)
  "Return where the last NEEDLE in HAYSTACK starts, or nil.
With END, the match must end at or before END."
  (unless (string-empty-p needle)
    (let ((pos 0) last)
      (while (and (setq pos (string-search needle haystack pos))
                  (or (null end) (<= (+ pos (length needle)) end)))
        (setq last pos
              pos (1+ pos)))
      last)))

(defun codec-extract-spoken (text &optional first)
  "Return the text of the last spoken summary in TEXT, or nil.
With FIRST non-nil, return the first complete one instead.  The
summary is between `codec-spoken-open' and `codec-spoken-close'."
  (if first
      (when-let* ((open (codec--first-index codec-spoken-open text))
                  (from (+ open (length codec-spoken-open)))
                  (close (codec--first-index codec-spoken-close text from)))
        (substring text from close))
    (when-let* ((close (codec--last-index codec-spoken-close text))
                (open (codec--last-index codec-spoken-open text close)))
      (substring text (+ open (length codec-spoken-open)) close))))

(defun codec--speakable (text)
  "Return TEXT without markdown or code, at most `codec-spoken-max-chars' long."
  (let ((text text))
    (pcase-dolist (`(,regexp . ,replacement)
                   '(("```\\(?:.\\|\n\\)*?```" . " ")           ; code blocks
                     ("`\\([^`\n]*\\)`" . "\\1")                 ; inline code
                     ("!?\\[\\([^]\n]*\\)\\]([^)\n]*)" . "\\1") ; links
                     ("<[^<>\n]*>" . " ")                       ; tags
                     ("^[ \t]*\\(?:#+\\|>+\\|[-*+]\\|[0-9]+[.)]\\)[ \t]+" . "")
                     ("[*`~]+" . "")
                     ("_+" . " ")
                     ("[[:space:]]+" . " ")
                     ("\\`[ -]+\\| +\\'" . "")))
      (setq text (replace-regexp-in-string regexp replacement text t)))
    (codec--cap text codec-spoken-max-chars)))

(defun codec--cap (text max)
  "Return TEXT cut to at most MAX characters at a sentence end or a word.
MAX nil means no limit."
  (if (or (null max) (<= (length text) max))
      text
    (let ((cut (substring text 0 max))
          (start 0)
          sentence-end)
      (while (string-match "[.!?]\\(?: \\|\\'\\)" cut start)
        (setq sentence-end (1+ (match-beginning 0))
              start (match-end 0)))
      (string-trim-right
       (cond ((and sentence-end (> sentence-end (/ max 2)))
              (substring cut 0 sentence-end))
             ((string-match " [^ ]*\\'" cut)
              (substring cut 0 (match-beginning 0)))
             (t cut))))))

(defun codec--mark-spoken (buffer start &optional first)
  "Give the last spoken summary in BUFFER after START an overlay.
With FIRST non-nil, mark the first one instead.  The overlay has
`codec-spoken-face', and is invisible if `codec-hide-spoken' is
non-nil.  Return the overlay, or nil."
  (with-current-buffer buffer
    (save-excursion
      (when-let* ((bounds (codec--spoken-bounds start first)))
        (let ((overlay (make-overlay (car bounds) (cdr bounds))))
          (overlay-put overlay 'codec-spoken t)
          (overlay-put overlay 'face 'codec-spoken-face)
          (overlay-put overlay 'evaporate t)
          (when codec-hide-spoken
            (overlay-put overlay 'invisible t))
          overlay)))))

(defun codec--spoken-bounds (start first)
  "Return (OPEN . END) of the last spoken summary after START, or nil.
With FIRST non-nil, return the first complete one instead.  Move point."
  (let ((case-fold-search nil))
    (if first
        (progn
          (goto-char start)
          (when-let* ((open (and (search-forward codec-spoken-open nil t)
                                 (match-beginning 0)))
                      (end (search-forward codec-spoken-close nil t)))
            (cons open end)))
      (goto-char (point-max))
      (when-let* ((end (and (search-backward codec-spoken-close start t)
                            (match-end 0)))
                  (open (search-backward codec-spoken-open start t)))
        (cons open end)))))

;;;; Speech

(defcustom codec-tts-backend 'say
  "The program that speaks the summaries.
say is the macOS say command; see `codec-say-program'.  piper is
Piper, which writes a WAV file that `codec-audio-player' plays; see
`codec-piper-program'.  nil means speak nothing."
  :type '(choice (const :tag "macOS say" say)
                 (const :tag "Piper" piper)
                 (const :tag "Do not speak" nil)))

(defcustom codec-say-program "say"
  "The say program, /usr/bin/say on macOS."
  :type 'string)

(defcustom codec-say-voice nil
  "The voice for say, as for say -v, or nil for the system voice.
Run say -v ? for the list."
  :type '(choice (const :tag "System voice" nil) string))

(defcustom codec-say-rate nil
  "The speech rate for say in words per minute, or nil for the default."
  :type '(choice (const :tag "Default" nil) natnum))

(defcustom codec-piper-program "piper"
  "The Piper program.  It reads text on stdin and writes a WAV file."
  :type 'string)

(defcustom codec-piper-model nil
  "The Piper voice model, an .onnx file with its .onnx.json next to it."
  :type '(choice (const :tag "Not set" nil) file))

(defcustom codec-piper-extra-args nil
  "More arguments for Piper, such as (\"--length_scale\" \"0.9\")."
  :type '(repeat string))

(defcustom codec-audio-player '("afplay")
  "The program and arguments that play Piper's WAV file.
The file name is appended.  For example (\"aplay\" \"-q\") on Linux."
  :type '(repeat string))

(defvar codec--tts-process nil "The process that speaks now, or nil.")
(defvar codec--speech-muted nil
  "Non-nil while codec mutes the listener because it speaks.")

(defun codec--speaking-p ()
  "Return non-nil if codec speaks now."
  (and codec--tts-process t))

(defun codec-speak (text)
  "Speak TEXT with `codec-tts-backend', and stop any speech before it.
The listener is muted until the speech ends."
  (interactive "sSay: ")
  (codec--kill-speech)
  (let ((text (string-trim text)))
    (if (or (string-empty-p text) (null codec-tts-backend))
        (codec--speech-ended)
      (codec--run-tts
       (lambda ()
         (pcase codec-tts-backend
           ('say (codec--say text))
           ('piper (codec--piper text))
           (backend (error "Unknown `codec-tts-backend': %s" backend))))))))

(defun codec-stop-speaking ()
  "Stop the speech at once, and unmute the listener.
The listener stays muted if you muted it with `codec-mute'."
  (interactive)
  (let ((speaking (codec--speaking-p)))
    (codec--kill-speech)
    (codec--speech-ended)
    (when (called-interactively-p 'interactive)
      (message (if speaking "codec: stopped speaking" "codec: not speaking")))))

(defun codec-pedal ()
  "Stop the speech if codec speaks, else toggle `codec-mode'.
Bind this to a foot pedal: one press interrupts the agent's summary
and lets you speak at once."
  (interactive)
  (if (codec--speaking-p)
      (codec-stop-speaking)
    (codec-mode 'toggle)))

(defun codec--run-tts (start)
  "Make the speech process with START, a function, and make it current.
Mute the listener for it.  On error, log it and end the speech."
  (condition-case err
      (progn
        (setq codec--tts-process (funcall start))
        (codec--speech-started))
    (error
     (setq codec--tts-process nil)
     (codec--log "cannot speak: %s" (error-message-string err))
     (message "codec: cannot speak: %s" (error-message-string err))
     (codec--speech-ended))))

(defun codec--speech-started ()
  "Mute the listener because codec speaks."
  (unless codec--speech-muted
    (setq codec--speech-muted t)
    (when (and codec-mode (not codec--muted))
      (codec--send "mute")))
  (force-mode-line-update t))

(defun codec--speech-ended ()
  "Unmute the listener after speech, unless the user muted it."
  (when codec--speech-muted
    (setq codec--speech-muted nil)
    (when (and codec-mode (not codec--muted))
      (codec--send "unmute")))
  (force-mode-line-update t))

(defun codec--kill-speech ()
  "Kill the speech process, if any, but leave the listener muted."
  (let ((process codec--tts-process))
    (setq codec--tts-process nil)
    (when process
      (delete-process process)
      (codec--delete-file (process-get process 'codec-wav)))))

(defun codec--reset-speech ()
  "Kill the speech process and forget the speech mute, without unmuting."
  (codec--kill-speech)
  (setq codec--speech-muted nil))

(defun codec--delete-file (file)
  "Delete FILE if it is non-nil and exists."
  (when (and file (file-exists-p file))
    (ignore-errors (delete-file file))))

(defun codec--tts-make-process (command)
  "Start the speech COMMAND and return its process.
Its output goes to `codec-log-buffer'."
  (let ((default-directory temporary-file-directory))
    (codec--log "speaking: %s" (mapconcat #'shell-quote-argument command " "))
    (make-process :name "codec-tts"
                  :command command
                  :buffer (get-buffer-create codec-log-buffer)
                  :connection-type 'pipe
                  :coding 'utf-8
                  :noquery t
                  :sentinel #'codec--tts-sentinel)))

(defun codec--say (text)
  "Start say for TEXT and return its process."
  (codec--tts-make-process
   (append (list codec-say-program)
           (and codec-say-voice (list "-v" codec-say-voice))
           (and codec-say-rate (list "-r" (number-to-string codec-say-rate)))
           (list text))))

(defun codec--piper (text)
  "Start Piper for TEXT and return its process.
When Piper is done, the sentinel plays its WAV file."
  (unless codec-piper-model
    (error "Set `codec-piper-model' to a Piper voice"))
  (let* ((wav (make-temp-file "codec-" nil ".wav"))
         (process (condition-case err
                      (codec--tts-make-process
                       (append (list codec-piper-program
                                     "--model" (expand-file-name codec-piper-model)
                                     "--output_file" wav)
                               codec-piper-extra-args))
                    (error (codec--delete-file wav)
                           (signal (car err) (cdr err))))))
    (process-put process 'codec-wav wav)
    (process-put process 'codec-then-play t)
    (process-send-string process (concat text "\n"))
    (process-send-eof process)
    process))

(defun codec--play (wav)
  "Start `codec-audio-player' for the file WAV and return its process."
  (let ((process (codec--tts-make-process
                  (append codec-audio-player (list wav)))))
    (process-put process 'codec-wav wav)
    process))

(defun codec--tts-sentinel (process _event)
  "Go on when the speech PROCESS exits.
After Piper, play its file; after the last step, unmute the listener."
  (unless (process-live-p process)
    (let ((current (eq process codec--tts-process))
          (ok (and (eq (process-status process) 'exit)
                   (zerop (process-exit-status process))))
          (wav (process-get process 'codec-wav)))
      (when (and current (not ok))
        (codec--log "%s failed: %s" (car (process-command process))
                    (process-exit-status process)))
      (if (and current ok (process-get process 'codec-then-play))
          (codec--run-tts
           (lambda ()
             (condition-case err
                 (codec--play wav)
               (error (codec--delete-file wav)
                      (signal (car err) (cdr err))))))
        (codec--delete-file wav)
        (when current
          (setq codec--tts-process nil)
          (codec--speech-ended))))))

;;;; Listener process

(defun codec--listener-directory ()
  "Return the listener directory."
  (file-name-as-directory
   (expand-file-name
    (or codec-listener-directory
        (let ((library (or (locate-library "codec.el" t)
                           load-file-name
                           buffer-file-name)))
          ;; Through straight's symlink to the repository, where
          ;; listener/ lives.
          (expand-file-name "listener" (file-name-directory
                                        (file-truename library))))))))

(defun codec--listener-base-command ()
  "Return the command that runs the listener, without options."
  (or codec-listener-command
      (let ((dir (codec--listener-directory)))
        (unless (executable-find codec-uv-program)
          (error "Cannot find %s; install uv or set `codec-uv-program'"
                 codec-uv-program))
        (list codec-uv-program "run" "--project" dir "--frozen" "--quiet"
              "python" (expand-file-name "codec_listener.py" dir)))))

(defun codec--listener-arguments ()
  "Return the listener options made from the customization options."
  (append (list "--model" codec-model
                "--device" (format "%s" codec-device)
                "--compute-type" (format "%s" codec-compute-type)
                "--silence-ms" (number-to-string codec-silence-ms))
          (mapcan (lambda (phrase) (list "--drop-phrase" phrase))
                  (copy-sequence codec-drop-phrases))
          codec-listener-extra-args))

(defun codec--make-process ()
  "Start the listener and return its process."
  (let* ((dir (codec--listener-directory))
         ;; A local directory, also when the current buffer is remote.
         (default-directory (if (file-directory-p dir)
                                dir
                              (expand-file-name "~/")))
         (process-environment (cons "PYTHONUNBUFFERED=1" process-environment))
         (command (append (codec--listener-base-command)
                          (codec--listener-arguments)))
         (stderr (make-pipe-process :name "codec-listener-stderr"
                                    :buffer (get-buffer-create codec-log-buffer)
                                    :noquery t
                                    :sentinel #'ignore)))
    (setq codec--stderr-process stderr)
    (codec--log "starting: %s" (mapconcat #'shell-quote-argument command " "))
    (make-process :name "codec-listener"
                  :command command
                  :connection-type 'pipe
                  :coding 'utf-8
                  :noquery t
                  :stderr stderr
                  :filter #'codec--filter
                  :sentinel #'codec--sentinel)))

(defun codec--stop-process ()
  "Ask the listener to quit, and kill it if it does not."
  (let ((process codec--process)
        (stderr codec--stderr-process))
    ;; Clear first, so that the sentinel takes the exit as expected.
    (setq codec--process nil
          codec--stderr-process nil)
    (when (process-live-p process)
      (ignore-errors (process-send-string process "quit\n"))
      (let ((deadline (+ (float-time) codec-shutdown-timeout)))
        (while (and (process-live-p process) (< (float-time) deadline))
          (accept-process-output process 0.05)))
      (when (process-live-p process)
        (codec--log "listener did not quit; killing it")
        (delete-process process)))
    (when (process-live-p stderr)
      (accept-process-output stderr 0)
      (delete-process stderr))))

(defun codec--send (command)
  "Send COMMAND to the listener if it is running."
  (when (process-live-p codec--process)
    (process-send-string codec--process (concat command "\n"))))

(defun codec--set-muted (flag)
  "Mute the listener if FLAG is non-nil, else unmute it.
The listener stays muted while codec speaks."
  (setq codec--muted flag)
  (codec--send (if (or flag codec--speech-muted) "mute" "unmute"))
  (force-mode-line-update t))

(defun codec--filter (process output)
  "Handle each whole line of OUTPUT from the listener PROCESS."
  (let ((pending (concat (process-get process 'codec-pending) output))
        (start 0))
    (while (string-match "\n" pending start)
      (let ((line (substring pending start (match-beginning 0))))
        (setq start (match-end 0))
        (when (eq process codec--process)
          (codec--handle-line line))))
    (process-put process 'codec-pending (substring pending start))))

(defun codec--handle-line (line)
  "Handle one protocol LINE from the listener."
  (let ((event (and (not (string-blank-p line))
                    (ignore-errors
                      (json-parse-string line :object-type 'plist
                                         :null-object nil
                                         :false-object nil)))))
    (if (and (plistp event) (plist-get event :type))
        (codec--handle-event event)
      (unless (string-blank-p line)
        (codec--log "not a protocol line: %s" line)))))

(defun codec--handle-event (event)
  "Act on the listener EVENT, a plist."
  (pcase (plist-get event :type)
    ("ready" (codec--handle-ready event))
    ("utterance" (codec--handle-utterance (plist-get event :text)))
    ("error"
     (let ((text (or (plist-get event :message) "unknown error")))
       (setq codec--last-error text)
       (codec--log "error: %s" text)
       (message "codec: %s" text)))
    ((or "listening" "muted" "stopped"))
    (type (codec--log "unknown event: %s" type)))
  (force-mode-line-update t))

(defun codec--handle-ready (event)
  "Note that the listener is ready, and on which device, from EVENT.
The device and compute type are absent from older listeners."
  (setq codec--ready t
        codec--device (let ((device (plist-get event :device))
                            (type (plist-get event :compute_type)))
                        (and (stringp device)
                             (if (stringp type)
                                 (format "%s, %s" device type)
                               device))))
  (codec--log "ready on %s" (or codec--device "an unknown device"))
  ;; Keep the hint that `codec--mute-for-target' showed.
  (unless codec--muted-for-target
    (message "codec: ready%s"
             (if codec--device (format " on %s" codec--device) ""))))

(defun codec--sentinel (process event)
  "Report an unexpected exit of the listener PROCESS with EVENT."
  (when (and (eq process codec--process)
             (not (process-live-p process)))
    (setq codec--process nil
          codec--error (or codec--last-error (string-trim event)))
    (message "codec: the listener stopped: %s (see %s)"
             codec--error codec-log-buffer)
    (force-mode-line-update t)))

(defun codec--log (format-string &rest args)
  "Add a line made from FORMAT-STRING and ARGS to `codec-log-buffer'."
  (with-current-buffer (get-buffer-create codec-log-buffer)
    (save-excursion
      (goto-char (point-max))
      (insert (format-time-string "%T codec: ")
              (apply #'format format-string args)
              "\n"))))

(provide 'codec)
;;; codec.el ends here
