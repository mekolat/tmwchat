(require 'tmwchat-inventory)

(defcustom tmwchat-trade-selling nil
  "List of selling items"
  :group 'tmwchat
  :type '(repeat (list :tag "Selling"
		       (integer :tag "ID")
		       (integer :tag "Price"))))

(defvar tmwchat--trade-player ""
  "Player you currently trade with")
(defvar tmwchat--trade-item-id 0)
(defvar tmwchat--trade-item-amount 0)
(defvar tmwchat--trade-item-price 0)
(defvar tmwchat--trade-player-offer 0)
(defvar tmwchat--trade-player-should-pay 0)
(defvar tmwchat--trade-item-index -10)
(defvar tmwchat--trade-cancel-timer nil
  "Timer to cancel trade if player hesitates too long")

(defun tmwchat-encode-base94 (value size)
  (let ((output "")
	(base 94)
	(start 33))
    (while (> value 0)
      (setq output (concat output (list (+ (% value base) start)))
	    value (/ value base)))
    (while (< (length output) size)
      (setq output (concat output (list start))))
    output))

(defun tmwchat-selllist ()
  (let ((data "\302\202B1"))
    (dolist (item tmwchat-trade-selling)
      (let* ((id (car item))
	     (price (cadr item))
	     (inv-amount (tmwchat-inventory-item-amount id)))
	(when (>= inv-amount 0)
	  (setq data (concat
		      data
		      (tmwchat-encode-base94 id 2)
		      (tmwchat-encode-base94 price 4)
		      (tmwchat-encode-base94 inv-amount 3))))))
    data))

(defun tmwchat-parse-buyitem (msg)
  (let ((result) (id 0) (amount 0) (price 0)
	(w (split-string msg)))
    (when (= (length w) 4)
      (setq id (string-to-int (nth 1 w))
	    price (string-to-int (nth 2 w))
	    amount (string-to-int (nth 3 w)))
      (when (and (> id 0)
		 (> price 0)
		 (> amount 0))
	(setq tmwchat--trade-item-id id
	      tmwchat--trade-item-price price
	      tmwchat--trade-item-amount amount
	      result t)))
    result))

(defun tmwchat-buyitem (nick &optional item-id price amount)

  (defun is-item-selling (id)
    (let (result)
      (dolist (s-info tmwchat-trade-selling)
	(when (= id (car s-info))
	  (setq result s-info)))
      result))

  (let* ((player-id (tmwchat-find-player-id nick))
	 (item-id (or item-id tmwchat--trade-item-id))
	 (price (or price tmwchat--trade-item-price))
	 (amount (or amount tmwchat--trade-item-amount))
	 (selling (is-item-selling item-id)))
    (unless (member nick tmwchat-blocked-players)
      (if (member player-id tmwchat-nearby-player-ids)
	  (if selling
	      (if (>= (tmwchat-inventory-item-amount item-id)
		      amount)
		  (let ((real-price (cadr selling)))
		    (setq tmwchat--trade-player nick)
		    (setq tmwchat--trade-player-should-pay
			  (* amount real-price))
		    (tmwchat-trade-request player-id))
		(whisper-message nick "I don't have enough."))
	    (whisper-message nick "I don't sell that."))
	(whisper-message nick "I don't see you nearby.")))))

(defun trade-request (info)
  (let ((spec   '((opcode       u16r)
		  (code         u8))))
    (tmwchat-send-packet spec
			 (list (cons 'opcode #xe6)
			       (cons 'code 4)))))  ;; reject

(defun trade-response (info)
  (let ((code (bindat-get-field info 'code)))
    (cond
     ((= code 0)
      (tmwchat-trade-log "Trade response: too far away")
      (whisper-message tmwchat--trade-player "You are too far away")
      (tmwchat--trade-reset-state)
      )
     ((= code 3)
      (tmwchat-trade-log "Trade from %s accepted." tmwchat--trade-player)
      (whisper-message
       tmwchat--trade-player
       (format "That will cost %d GP." tmwchat--trade-player-should-pay))
      (setq tmwchat--trade-cancel-timer
	    (run-at-time 120 nil 'tmwchat-trade-cancel-request))
      (let ((index (tmwchat-inventory-item-index tmwchat--trade-item-id)))
	(setq tmwchat--trade-item-index index)
	(if (> index -10)
	    (progn
	      (tmwchat-trade-add-item index tmwchat--trade-item-amount)
	      (tmwchat-trade-add-complete))
	  (progn
	    (tmwchat-trade-cancel-request)
	    (tmwchat-trade-log "I cancel trade.")))))
     ((= code 4)
      (tmwchat--trade-reset-state)
      (tmwchat-trade-log "Trade canceled." tmwchat--trade-player)))))

(defun trade-item-add (info)
  (let ((amount (bindat-get-field info 'amount))
	(id (bindat-get-field info 'id)))
    (tmwchat-trade-log "SMSG_TRADE_ITEM_ADD id=%d amount=%d" id amount)
    (cond
     ((= id 0)
      (setq tmwchat--trade-player-offer amount))
     ((> id 0)
      (whisper-message tmwchat--trade-player "Currently I accept only GP")
      (tmwchat-trade-cancel-request))
     (t
      (tmwchat-trade-log "Trade error.")
      (whisper-message tmwchat--trade-player "Trade error.")
      (tmwchat-trade-cancel-request)))))

(defun trade-item-add-response (info)
  (let ((index (bindat-get-field info 'index))
	(amount (bindat-get-field info 'amount))
	(code (bindat-get-field info 'code)))
    (cond
     ((= code 0)
      (player-inventory-remove (list (cons 'index index)
				     (cons 'amount amount)))
      (tmwchat-trade-log "SMSG_TRADE_ITEM_ADD_RESPONSE index=%d amount=%d" index amount))
     ((= code 1)
      (tmwchat-trade-log "%s is overweight" tmwchat--trade-player)
      (whisper-message tmwchat--trade-player "You seem to be overweight.")
      (tmwchat-trade-cancel-request))
     ((= code 2)
      (tmwchat-trade-log "%s has no free slots" tmwchat--trade-player)
      (whisper-message tmwchat--trade-player "You don't have free slots.")
      (tmwchat-trade-cancel-request))
     (t
      (tmwchat-trade-log "Unknown trade error.")
      (whisper-message tmwchat--trade-player "Unknown trade error.")
      (tmwchat-trade-cancel-request)))))

(defun trade-cancel (info)
  (tmwchat-trade-log "Trade canceled.")
  (when (timerp tmwchat--trade-cancel-timer)
    (cancel-timer tmwchat--trade-cancel-timer))
  (tmwchat--trade-reset-state))

(defun trade-ok (info)
  (let ((who (bindat-get-field info 'who)))
    (cond
     ((= who 0)
      (tmwchat-trade-log "Trade OK: self"))
     (t
      (tmwchat-trade-log "Trade OK: %s" tmwchat--trade-player)
      (cond
       ((>= tmwchat--trade-player-offer tmwchat--trade-player-should-pay)
	(tmwchat-trade-ok))
       ((< tmwchat--trade-player-offer tmwchat--trade-player-should-pay)
	(whisper-message tmwchat--trade-player "Your offer makes me sad.")
	(tmwchat-trade-cancel-request)))))))

(defun trade-complete (info)
  (tmwchat-trade-log "Trade with %s completed." tmwchat--trade-player)
  (setq tmwchat-money (+ tmwchat-money tmwchat--trade-player-offer))
  (when (timerp tmwchat--trade-cancel-timer)
    (cancel-timer tmwchat--trade-cancel-timer))
  (tmwchat--trade-reset-state))

(defun tmwchat-trade-add-item (index amount)
  (let ((spec  '((opcode       u16r)
		 (index        u16r)
		 (amount       u32r))))
    (tmwchat-send-packet spec
			 (list (cons 'opcode #x0e8)
			       (cons 'index index)
			       (cons 'amount amount)))))
(make-variable-buffer-local 'tmwchat-trade-add-item)

(defun tmwchat-trade-add-complete ()
  (write-u16 #x0eb))
(make-variable-buffer-local 'tmwchat-trade-add-complete)

(defun tmwchat-trade-ok ()
  (write-u16 #x0ef))
(make-variable-buffer-local 'tmwchat-trade-ok)

(defun tmwchat-trade-request (id)
  (let ((spec '((opcode     u16r)
	        (id     vec    4))))
    (tmwchat-send-packet spec
			 (list  (cons 'opcode #x0e4)
				(cons 'id     id)))))
(make-variable-buffer-local 'tmwchat-trade-request)

(defun tmwchat-trade-cancel-request ()
  (write-u16 #x0ed))
(make-variable-buffer-local 'tmwchat-trade-cancel-request)

(defun tmwchat--trade-reset-state ()
  (setq tmwchat--trade-player ""
        tmwchat--trade-player-offer 0
        tmwchat--trade-player-should-pay 0
	tmwchat--trade-item-id 0
	tmwchat--trade-item-amount 0
	tmwchat--trade-item-price 0
	tmwchat--trade-item-index -10))

(defun tmwchat-trade-log (&rest args)
  (with-current-buffer (get-buffer-create "TMWChat-trade")
    (let ((msg (apply 'format args)))
      (setq msg (format "[%s] %s" (tmwchat-time) msg))
      (goto-char (point-max))
      (insert msg)
      (newline))))

(provide 'tmwchat-trade)