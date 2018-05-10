;;; socket-actors.lisp
;;; Actor-protected TCP sockets

(in-package :gossip)

(defvar *tcp-connection-table* (kvs:make-store ':hashtable :test 'eql) "Memoizes open connections")

; herein we sometimes refer to these things as "connections"
(defclass socket-actor (ac:actor)
  ()
  (:documentation "An actor whose job is to gatekeep a two-way TCP connected socket"))

(defun make-ip-key (address port)
  (if (and (integerp address)
           (null port))
      address ; means port is already folded into real-address
      (+ (ash (usocket::host-to-hbo address) 16) port)))

(defun memoize-connection (address port object)
  (let ((key (make-ip-key address port)))
    (kvs:relate-unique! *tcp-connection-table* key object)))
  
(defun unmemoize-connection (address port)
  (let ((key (make-ip-key address port)))
    (kvs:remove-key! *tcp-connection-table* key)))

(defun lookup-connection (address port)
  "Returns open pipe to address/port, if any"
  (let ((key (make-ip-key address port)))
    (kvs:lookup-key *tcp-connection-table* key)))

;;; Actor property functions. These can be called safely by anybody--not just by the actor itself.
(defmethod get-socket ((sa socket-actor))
  "Returns socket this actor controls"
  (ac:get-property sa :socket))

(defmethod get-outbox ((sa socket-actor))
  "Returns outbox this actor controls"
  (ac:get-property sa :outbox))

(defmethod get-thread ((sa socket-actor))
  "Returns select-loop thread that monitors this actor's socket"
  (ac:get-property sa :thread))

(defmethod get-peer-address ((sa socket-actor))
  "Returns peer-address of this socket"
  (ac:get-property sa :peer-address))

(defmethod get-peer-port ((sa socket-actor))
  "Returns peer-port of this socket"
  (ac:get-property sa :peer-port))

;;; End of actor property functions

(defun send-socket-receive-message (actor)
  "Send a socket-receive message to an actor."
  (when (debug-level 3)
    (debug-log "Socket receive" actor))
  (ac:send actor :receive-socket-data))

(defun send-socket-shutdown-message (actor)
  "Send a socket-shutdown message to an actor."
  (when (debug-level 3)
    (debug-log "Socket shutdown" actor))
  (ac:send actor :shutdown))

(defmethod select-loop ((actor socket-actor))
  "Loop that monitors read-readiness of socket and sends messages
  to actor when ready. This should be run in a separate
  thread, not in an actor.
  (If you run it in an actor, that actor and the thread containing
  it will block, and that actor will no longer be able to receive
  messages.)"
  (let ((socket (get-socket actor)))
    (loop
      (multiple-value-bind (success errno status)
                           (ccl::process-input-wait* (ccl::socket-device (usocket:socket-stream socket)) nil)
        (cond ((and (null success) ; if success and errno are both nil, we timed out without error
                    (null errno))
               ; When no further data available, fall through and end loop
               (send-socket-shutdown-message actor)
               (return))
              ((or errno
                   (and (/= status 0)
                        (/= status #$POLLIN)))
               ; presumably the POLLHUP bit is set, sometimes in addition to #$POLLIN
               (when (not (zerop (logand status #$POLLHUP)))
                   (send-socket-shutdown-message actor))
               (format t  "~%Errno = ~D, status=~D" errno status))
              (t
               (send-socket-receive-message actor)))))))
  
(defun make-select-thread (actor)
  (mpcompat:process-run-function "Select loop" nil 'select-loop actor))

(defmethod socket-actor-dispatcher (&rest msg)
  (let ((socket-cmd (first msg))
        (actor (ac:current-actor)))
    (when actor
      (let ((socket (get-socket actor)))
        (case socket-cmd
          (:send-socket-data
           (let* ((socket (get-socket actor))
                  (stream (usocket:socket-stream socket))
                  (payload (second msg)))
             (cond ((and (usocket:stream-usocket-p socket)
                         (open-stream-p stream))
                    (loenc:serialize payload stream)
                    (finish-output stream))
                   (t (ac:self-call :shutdown)))))
          (:receive-socket-data
           (let ((outbox (get-outbox actor))
                 (stream (usocket:socket-stream socket))
                 (object nil))
             (when (listen stream) ; it is ****VERY**** important to check this here.
               ; Why? Because many :receive-socket-data messages can pile up because the concurrent select-loop can show the socket has data
               ;      _while_ loenc:deserialize is happening. The result will be that (current-actor) will hang in the next loenc:deserialize
               ;      because there won't really be any data waiting, because the previous loenc:deserialize used it all up.
               ;      We should probably set a flag in the actor to better coordinate between
               ;      the select-loop and the code here, and prevent unnecessary :receive-socket-data messages, but for now we'll just check listen.
               (setf object (loenc:deserialize stream))
               (ac:send outbox actor object) ; first parameter is this actor, so we can know where object came from
               )))
          (:shutdown
           ; Kill the select thread, close the socket. Leave outbox alone in case any output objects remain.
           (let ((socket (get-socket actor))
                 (address (get-peer-address actor))
                 (port (get-peer-port actor)))
             (when (usocket:stream-usocket-p socket) (usocket:socket-close socket))
             (process-kill (get-thread actor))
             (unmemoize-connection address port))))))))

(defun ensure-open-socket (address port)
  "Initiates a TCP connection from this machine to another.
   If second value is non-nil, it indicates some kind of error that makes first value invalid."
  (when (debug-level 3)
    (debug-log "Opening socket to " (usocket::host-to-vector-quad address) port))
  (multiple-value-bind (socket errorp)
                       (handler-case (usocket:socket-connect address port :protocol ':stream :element-type '(unsigned-byte 8))
                         (T (e) (values nil e)))
    (cond ((and (not errorp)
                (usocket:stream-usocket-p socket))
           socket)
          (t (values socket (or errorp :INVALID-SOCKET))))))

(defun ensure-connection (address port &optional outbox)
  "Find or make an actor-mediated connection to given address and port.
  If second value is non-nil, it indicates some kind of error that makes first value invalid."
  (or (lookup-connection address port)
      (multiple-value-bind (socket errorp)
                           (ensure-open-socket address port)
        (cond ((not errorp)
               (make-socket-actor socket outbox))
              (t (values socket errorp))))))
      
(defun make-socket-actor (socket &optional outbox)
  "Wraps an actor around an open socket connection. Returns the actor.
   You can pass in your own argument for outbox; if nil a mailbox will be created automatically.
   Given outbox could be either a mailbox, an actor, or a function that acts as a continuation
   for handling received objects."
  (let* ((outbox (or outbox (mpcompat:make-mailbox)))
         (actor  (make-instance 'socket-actor :fn 'socket-actor-dispatcher))
         (address (usocket:get-peer-address socket))
         (port    (usocket:get-peer-port socket)))
    (ac:set-property actor :peer-address address)
    (ac:set-property actor :peer-port    port)
    (ac:set-property actor :outbox outbox)
    (ac:set-property actor :socket socket)
    (ac:set-property actor :thread (make-select-thread actor))
    (memoize-connection address port actor)
    actor
    ))