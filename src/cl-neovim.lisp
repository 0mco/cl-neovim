(in-package #:cl-neovim)

(defparameter *debug-stream* (make-broadcast-stream))
(defvar *using-host* NIL "Variable that host binds to T when it loads plugins.")

(defvar *specs* NIL "A list of all the specs nvim needs.")
(defvar *path* NIL "A list of all the specs nvim needs.")
(defvar *nvim-types* (mrpc:define-extension-types
                       '(0
                         Buffer
                         Window
                         Tabpage)))

(cl:defun plist->hash (plist)
  "Convert property list plist into hash table. Keys are transformed into
   lowercase strings."
  (let ((hash (make-hash-table :test #'equal)))
    (loop for (k v) on plist by #'cddr
          do (setf (gethash (map 'string #'char-downcase (symbol-name k)) hash) v)
          finally (return hash))))

(cl:defun lisp->vim-name (lisp-name)
  "Convert lisp symbol into vim name. Basically turns hyphen-separated name
   into camelcase string."
  (let* ((str (symbol-name lisp-name))
         (parts (split-sequence:split-sequence #\- str)))
    (format nil "~{~:(~A~)~^~}" parts)))

(cl:defun symbol-name= (symbol1 symbol2)
  "Compare two symbols by their name."
  (and (symbolp symbol1) (symbolp symbol2)
       (string= (symbol-name symbol1) (symbol-name symbol2))))

(cl:defun mklst (obj) (if (listp obj) obj (list obj)))

(cl:defun alist-stable-intersection (as bs)
  "Intersection between 2 association lists as and bs, where the order is the
   same as in as and the values are associations from as."
  (let ((bs-alist (make-alist bs)))
    (remove-if-not #'(lambda (a) (assoc (car (mklst a)) bs-alist :test #'symbol-name=)) as)))

(cl:defun make-alist (lst)
  "Wrap a list of symbols (or lists) to a list of lists with first element
   being symbol."
  (mapcar #'mklst lst))

(cl:defun short-names (args)
  "Return short names for &opts arguments"
  (mapcar #'(lambda (arg) (if (and (not (second arg))
                                   (or (symbol-name= (first arg) 'args)
                                       (symbol-name= (first arg) 'nargs)))
                            NIL
                            (or (second arg) (first arg))))
          (make-alist args)))

(cl:defun generate-arglist (args args-opts declare-opts nvim-opts)
  "Generate argument list that will properly parse neovim's format of passed
   arguments. "
  (if (not (listp nvim-opts))
    (fill-args-into-opts args declare-opts nvim-opts) 
    (let* ((args-opts (append '((nargs) (args)) (mapcar #'mklst args-opts)))
           (nvim-opts (fill-args-into-opts args declare-opts nvim-opts)) 
           (ordered-opts (alist-stable-intersection (mapcar #'mklst nvim-opts) (append '((nargs) (args)) declare-opts)))
           (ignored-opts (mapcar #'(lambda (arg)
                                     (if (> (length arg) 1)
                                       arg
                                       (or (assoc (car arg) args-opts :test #'symbol-name=) (gensym))))
                                 ordered-opts))
           (short-arg-names (short-names ignored-opts)))
      short-arg-names)))

(cl:defun fill-declare-opts (declare-opts)
  "If user specified just '[opt] in declare opts, fill it out with the default
   value. Don't modify the opts that were defined along with their values
   '([opt] [val])."
  (let ((defaults '((nargs "*") (complete "") (range "") (count "") (bang "") (bar "") (register ""))))
    (mapcar #'(lambda (opt) (if (listp opt)
                              opt
                              (assoc opt defaults :test #'symbol-name=)))
            declare-opts)))

(cl:defun fill-args-into-opts (args declare-opts nvim-opts) 
  "Based on the value of nargs declaration either fill in and replace nargs
   with actual user expected arguments, or ignore them, and replace args with
   actual user arguments."
  (if (listp nvim-opts)
    (let* ((nargs (second (assoc 'nargs declare-opts :test #'symbol-name=)))
           (opts-wo-nargs (if (or (not nargs) (string= "0" nargs))
                            (remove 'nargs nvim-opts :test #'symbol-name=)
                            (substitute `(nargs ,args) 'nargs nvim-opts :test #'symbol-name=))))
      (substitute `(args ,args) 'args opts-wo-nargs :test #'symbol-name=))
    (subst args 'args nvim-opts :test #'symbol-name=)))

(cl:defun generate-specs (declare-opts type)
  "Generate the specs from declare opts user specified."
  (let* ((opts (mapcar #'(lambda (l) (list (intern (symbol-name (first l)) 'keyword) (rest l))) declare-opts))
         (opts (alexandria:flatten (alexandria:alist-plist opts)))
         (opts (if (and (string= type "autocmd") (not (getf opts :pattern)))
                 (append '(:pattern "*") opts)
                 opts)))
     (substitute :eval :vim-eval opts)))

(cl:defun generate-callback-name (type name spec-opts)
  "Generate the callback name neovim will use when referring to this
   function/command/autocmd."
  (if *path*
    (concatenate 'string
                 (format nil "~A:~A:~A" *path* type name)
                 (if (string= type "autocmd") (format nil ":~A" (getf spec-opts :pattern)) ""))
    name))

(cl:defun construct-callback (type nvim-opts name-args-decls-body)
  "Construct the callback, register it with proper name, and generate specs
   based on the arguments passed."
  (destructuring-bind (fun name qualifiers args-and-opts docstring decls body) (form-fiddle:split-lambda-form (cons 'defun name-args-decls-body))
    (declare (ignore fun))
    (destructuring-bind (&optional args arglist-opts) (split-sequence:split-sequence '&opts args-and-opts :test #'symbol-name=)
      (let* ((name (if (stringp name) name (lisp->vim-name name)))
             (sync (member :sync qualifiers))
             (raw-declare-opts (rest (assoc 'opts (cdar decls) :test #'symbol-name=)))
             (declare-opts (fill-declare-opts raw-declare-opts))
             (not-a-host-p (or (not (boundp *using-host*))
                               (and (boundp *using-host*) (not *using-host*))))
             (arglist (generate-arglist args arglist-opts declare-opts nvim-opts))
             (spec-opts (generate-specs declare-opts type))
             (callback-name (generate-callback-name type name spec-opts))
             (r (gensym)))
        `(progn
           (push (plist->hash (list :sync ,(if sync 1 0)
                                    :name ,name
                                    :type ,type
                                    :opts (plist->hash ',spec-opts)))
                 *specs*)
           (,(if sync 'mrpc:register-request-callback 'mrpc:register-notification-callback)
             ,callback-name
             #'(lambda ,(if not-a-host-p args-and-opts `(&rest ,r))
                 ,docstring
                 (destructuring-bind ,@(if not-a-host-p '(() ()) `(,arglist ,r))
                   ,@body))))))))

(defmacro defcommand (&rest name-args-decls-body)
  ; nvim-options for command found in runtime/autoload/remote/define.vim#L54-L87
  (construct-callback "command" '(nargs range count bang register vim-eval) name-args-decls-body))

(defmacro defautocmd (&rest name-args-decls-body)
  ; nvim-options for autocmd found in runtime/autoload/remote/define.vim#L121-L128
  (construct-callback "autocmd" 'args name-args-decls-body))

(defmacro defun (&rest name-args-decls-body)
  ; nvim-options for function found in runtime/autoload/remote/define.vim#L158-L166
  (construct-callback "function" '(args vim-eval) name-args-decls-body))

(cl:defun send-command (command async &rest args)
  "Send nvim command to neovim socket and return the result."
  (let ((mrpc:*extended-types* *nvim-types*))
    (if async
      (mrpc:notify command args)
      (mrpc:request command args NIL))))

(cl:defun connect (&rest args &key host port file)
  (let ((mrpc:*extended-types* *nvim-types*))
    (apply #'mrpc:connect args)))
