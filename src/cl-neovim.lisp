(in-package #:cl-neovim)


(defparameter *log-stream* *standard-output*)
(defvar *using-host* NIL "Variable that host binds to T when it loads plugins.")

(defvar *specs* NIL "A list of all the specs nvim needs.")
(defvar *path* "" "Variable that gets set to path to plugin.")
(defvar *nvim-types* (mrpc:define-extension-types
                       '(0
                         Buffer
                         Window
                         Tabpage)))
(defvar *nvim-instance* NIL "Binds to the last connection to neovim")


(cl:defun connect (&rest args &key host port file)
  (let ((mrpc:*extended-types* *nvim-types*))
    (setf *nvim-instance* (apply #'make-instance 'mrpc:client args))))

(cl:defun listen-once (&optional (instance *nvim-instance*))
  "Block execution listening for a new message for instance."
  (mrpc::run-once (mrpc::event-loop instance)))

(cl:defun call/s (command &rest args)
  "Send nvim command to neovim socket and return the result."
  (let ((mrpc:*extended-types* *nvim-types*))
    (apply #'mrpc:request *nvim-instance* command args)))

(cl:defun call/a (command &rest args)
  "Send nvim command to neovim socket asynchronously, returning the control
back to the caller immediately and discarding all return values/errors."
  (let ((mrpc:*extended-types* *nvim-types*))
    (apply #'mrpc:notify *nvim-instance* command args)))
