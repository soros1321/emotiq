;;;; block.lisp

(in-package :cosi/proofs)




                                                                                ;
(defclass block ()
  ((protocol-version
    :accessor protocol-version
    :initform 1
    :documentation 
      "Version of the protocol/software, an integer.")

   (epoch                               ; aka "height"
    :initarg :epoch :accessor epoch
    :initform nil 
    :documentation
      "The integer of the epoch that this block is a part of."
      ;; height: "Position of block in the chain, an integer."
      )

   (prev-block
    :accessor prev-block
    :documentation "Previous block (nil for genesis block).")
   (prev-block-hash
    :accessor prev-block-hash
    :documentation "Hash of previous block (nil for genesis block).")

   (merkle-root-hash
    :accessor merkle-root-hash
    :documentation "Merkle root hash of block-transactions.")

   (block-timestamp
    :accessor block-timestamp
    :documentation 
      "Approximate creation time in seconds since Unix epoch.")

   (public-keys-of-witnesses
    :accessor public-keys-of-witnesses
    :documentation
    "Sequence of public keys of validators 1:1 w/witness-bitmap slot.")
   (witness-bitmap
    :initform 0
    :documentation 
    "Use methods ith-witness-signed-p and set-ith-witness-signed-p; do not
     access directly. Internally, the bitmap is represented as a bignum. Each
     position of the bitmap corresponds to a vector index, its state tells you
     whether that particular potential witness signed.")
   (block-signature
    :accessor block-signature
    :documentation
    "A signature over the whole block authorizing all transactions.")

   ;; Transactions is generally what's considered the main contents of a block
   ;; whereas the rest of the above comprises what's known as the 'block header'
   ;; information.
   (transactions
    :accessor transactions
    :documentation "A sequence of transactions"))
  (:documentation "A block on the Emotiq blockchain."))



(defvar *unix-epoch-ut* (encode-universal-time 0 0 0 1 1 1970 0)
  "The Unix epoch as a Common Lisp universal time.")



;;; CREATE-BLOCK: TRANSACTIONS should be a sequence of TRANSACTION instances.
;;; The order of the elements of TRANSACTIONS is fixed in the block once the
;;; block is created and cannot be changed. The order is somewhat flexible
;;; except for the following partial ordering constraints:
;;;
;;;   (1) a coinbase transaction must come first; and
;;;
;;;   (2) for any two transactions Tx1, Tx2, if the input of Tx2 spends the
;;;   output of Tx1, Tx1 must come before Tx2.
;;;
;;; This function does not check the order. However, validators check the order,
;;; and they can require this order for a block to be considered valid.
;;; Software may also rely upon this order, e.g., as a search heuristic.

(defun create-block (epoch prev-block transactions)
  (let ((block (make-instance 'block :epoch epoch)))
    (setf (prev-block block) prev-block)
    (setf (prev-block-hash block) 
          (if (null prev-block)
              nil
              (hash-block prev-block)))
    (setf (merkle-root-hash block)
          (compute-merkle-root-hash transactions))
    (setf (transactions block) transactions)
    (setf (block-timestamp block) 
          (- (get-universal-time) *unix-epoch-ut*))
    block))



(defun hash/256d (&rest hashables)
  "Double sha-256-hash HASHABLES, returning a hash:hash/256 hash value
   representing a 32 raw-byte vector. This is the hash function
   Bitcoin uses for hashing nodes of a merkle tree and for computing
   the hash of a block."
  (hash:hash/256 (apply #'hash:hash/256 hashables)))



(defun hash-block (block)
  (apply #'hash/256d (serialize-block-octets block)))



(defparameter *names-of-block-slots-to-serialize*
  '(protocol-version 
    epoch
    prev-block-hash
    merkle-root-hash
    block-timestamp
    public-keys-of-witnesses
    witness-bitmap
    block-signature)
  "These slots are serialized and then hashed. The hash is stored as
   the prev-block-hash on a newer block on a blockchain.")



(defun serialize-block-octets (block)
  "Return a serialization of BLOCK as a list of octet vectors for the slots in
   \*names-of-block-slots-to-serialize*. It is an error to call this before all
   those slots are bound. This is to be used to hash a previous block, i.e., on
   that has been fully formed and already been added to the blockchain."
  (loop for slot-name in *names-of-block-slots-to-serialize*
        collect (loenc:encode (slot-value block slot-name))))



;;; COMPUTE-MERKLE-ROOT-HASH: construct a merkle root for a sequence of
;;; TRANSACTIONS according to bitcoin.org Bitcoin developer reference doc, here:
;;; https://bitcoin.org/en/developer-reference#block-versions

(defun compute-merkle-root-hash (transactions)
  (compute-merkle
   ;; transactions is a sequence, i.e., list or vector
   (if (consp transactions)
       ;; (optimized for list case)
       (loop for tx in transactions
             as tx-out-id = (get-txid-out-id tx)
             collect tx-out-id)
       (loop for i from 0 below (length transactions)
             as tx = (elt transactions i)
             as tx-out-id = (get-txid-out-id tx)
             collect tx-out-id))))



(defun get-txid-out-id (transaction)
  "Get the identifier of TRANSACTION an octet vector of length 32, which can be
   used to hash the transactions leaves of the merkle tree to produce the
   block's merkle tree root hash. It represents H(PubKey, PedComm), or possibly
   a superset thereof."
  (vec-repr:bev-vec (hash:hash-val (hash-transaction transaction))))

;; In Bitcoin this is known as the TXID of the transaction.



(defun hash-transaction (transaction)
  "Produce a hash for TRANSACTION, including the pair (PubKey, PedComm).
   The resulting hash's octet vector is usable as a transaction ID."
  (hash/256d transaction))



(defun compute-merkle (nodes)
  "Compute merkle root hash on nonempty list of hashables NODES."
  (assert (not (null nodes)) () "NODES must not be null.")
  (cond
    ((null (rest nodes))                ; just 1
     (hash/256d (first nodes)))
    (t (compute-merkle-pairs nodes))))



(defun compute-merkle-pairs (nodes)
  "Compute the merkle root on NODES, a list of two or more hash
   objects."
  (if (null (rest (rest nodes)))
      ;; 2 left
      (hash/256d (first nodes) (second nodes))
      ;; three or more:
      (loop for (a b . rest?) on nodes by #'cddr
            when (and (null rest?) (null b))
              do (setq b a) ; odd-length row case: duplicate last row item
            collect (hash/256d a b)
              into row
            finally (return (compute-merkle-pairs row)))))



(defmethod ith-witness-signed-p (block i)
  "Return true or false (nil) according to whether the ith witness has signed."
  (with-slots (witness-bitmap) block
    (logbitp i witness-bitmap)))

(defmethod set-ith-witness-signed-p (block i signed-p)
  "Set signed-p to either true or false (nil) for witness at position i."
  (with-slots (witness-bitmap) block
    (setf witness-bitmap
          (dpb (if signed-p 1 0)
               (byte 1 i)
               witness-bitmap))))