(require 'cl)
(require 'core-ext)
(require 'inflections)
(require 'rails-lib)

(defvar rails/current-buffer nil)

(defstruct rails/resource type ;; symbol, required
                          display-name ;; string, required
                          menu-group ;; string required
                          boundle-name ;; string
                          dir file-ext file-suffix skip-file-suffix ;; string
                          expand-in-menu ;; boolean
                          pluralize ;; boolean
                          file-pattern ;; pattern
                          link-to ;; list
                          test-to ;; symbol
                          get-action-func set-action-func ;; commandp
                          (weight 1)) ;; integer required

(defstruct rails/resource-buffer type
                                 resource-name
                                 file-name
                                 get-action-func
                                 set-action-func
                                 (weight 1)) ;; must be integer

(defstruct rails/resource-item file
                               display-name
                               resource-type
                               resource-menu-group
                               resource-display-name)

(defvar rails/resources/list-defined nil)

;;; ---------------------------------------------------------
;;; - CRUD functions
;;;

(defun* rails/defresource (type display-name &key menu-group bundle-name
                                                  dir file-suffix file-ext
                                                  skip-file-suffix
                                                  pluralize file-pattern
                                                  expand-in-menu
                                                  link-to test-to
                                                  get-action-func set-action-func
                                                  weight)
  (when (rails/resources/find type)
    (error (format "Resource %s already defined" type)))
  (let (res)
    (setq res (make-rails/resource :type type
                                   :menu-group (if menu-group (symbol-name menu-group) "acore")
                                   :display-name display-name
                                   :dir (if (string-ext/end-p dir "/") dir (concat dir "/"))
                                   :file-suffix file-suffix
                                   :skip-file-suffix skip-file-suffix
                                   :file-ext  (if (string-ext/start-p file-ext ".")
                                                  file-ext
                                                (when file-ext
                                                  (concat "." file-ext)))
                                   :link-to (if (listp link-to) link-to (list link-to))
                                   :test-to (if (symbolp test-to)
                                                test-to
                                              (error "rails/resource#test-to must be the symbol"))
                                   :pluralize pluralize
                                   :expand-in-menu expand-in-menu
                                   :file-pattern file-pattern
                                   :get-action-func get-action-func
                                   :set-action-func set-action-func
                                   :weight (if (not weight) 1 weight)))
    (add-to-list 'rails/resources/list-defined res t)))

(defun rails/resources/find (resource-type)
  (when (stringp resource-type)
    (setq resource-type (intern resource-type)))
  (find resource-type rails/resources/list-defined :key 'rails/resource-type))

(defun rails/resources/delete (resource-type)
  (setq
   rails/resources/list-defined
   (remove* resource-type rails/resources/list-defined :key 'rails/resource-type)))

(defun rails/resources/clear ()
  (setq rails/resources/list-defined nil))

;;; ---------------------------------------------------------
;;; - Comparable functions
;;;
(defun rails/resources/get-compared-resources-alist (resource-or-file)
  (let (resources)
    (setq resources
          (loop for res in rails/resources/list-defined
                when (or
                      (and (rails/resource-p resource-or-file)
                           (string-ext/start-p (rails/resource-dir res)
                                               (rails/resource-dir resource-or-file)))
                      (and (stringp resource-or-file)
                           (string-ext/start-p resource-or-file
                                               (rails/resource-dir res))))
                collect res))
    (when (rails/resource-p resource-or-file)
      (add-to-list 'resources resource-or-file))
    (loop for res in resources
          for file-mask = ""
          for file-suffix = ""
          collect
          (progn
            ;; skip-file-suffix
            (when-bind (skip-file-suffix (rails/resource-skip-file-suffix res))
              (setq file-suffix skip-file-suffix))
            ;; file-suffix
            (when-bind (file-suffix (rails/resource-file-suffix res))
              (setq file-mask (concat file-mask file-suffix)))
            ;; file-ext
            (when-bind (file-ext (rails/resource-file-ext res))
              (setq file-mask (concat file-mask file-ext)))
            (setq file-mask (format "^\\(.*%s\\)%s$"
                                    (regexp-quote file-suffix)
                                    (regexp-quote file-mask)))
            (cons res
                  file-mask)))))

(defun rails/resources/compare-file-by-compared-alist (file alist)
  (let ((max-weight 0)
        max-match
        max-res)
    (loop for (res . regexp) in alist
          for dir    = (rails/resource-dir res)
          for in-dir = (string-ext/start-p file dir)
          for match  = (string-ext/string=~ regexp
                                            (string-ext/cut file
                                                            dir
                                                            :begin)
                                            $1)
          when (and in-dir
                    match
                    (> (rails/resource-weight res) max-weight))
          do
          (progn
            (setq max-weight (rails/resource-weight res)
                  max-match match
                  max-res res)))
    (when max-res
      (cons max-res max-match))))

;;; ---------------------------------------------------------
;;; - Lookup resource-buffer for file
;;;

(defun rails/resources/get-buffer-for-file(root file)
  (let* ((comp-alist (rails/resources/get-compared-resources-alist file))
         (res-alist (rails/resources/compare-file-by-compared-alist file
                                                                    comp-alist))
         res-name
         res)
    (when res-alist
      (setq res-name (cdr res-alist)
            res      (car res-alist))
      (when (rails/resource-pluralize res)
        (setq res-name (pluralize-string res-name)))
      (when-bind (pattern (rails/resource-file-pattern res))
        (setq pattern (replace-regexp-in-string "{name}" "\\\\(.*\\\\)" pattern))
        (setq res-name (string-ext/string=~ pattern res-name $1)))
      (make-rails/resource-buffer :type (rails/resource-type res)
                                  :resource-name res-name
                                  :file-name file
                                  :weight (rails/resource-weight res)
                                  :get-action-func (rails/resource-get-action-func res)
                                  :set-action-func (rails/resource-set-action-func res)))))

;;; ---------------------------------------------------------
;;; - Lookup associated resources by resource-buffer
;;;

(defun rails/resources/resource-files-to-items (resource files)
  (unless (listp files)
    (setq files (list files)))
  (loop for it in files collect
        (let ((name it)
              (file it)
              (dir (rails/resource-dir resource)))
          (when (consp it)
            (setq name (car it)
                  file (cdr it)))
          (unless (string-ext/start-p file dir)
            (setq file (concat dir file)))
          (make-rails/resource-item :display-name name
                                    :file file
                                    :resource-type (rails/resource-type resource)
                                    :resource-menu-group (rails/resource-menu-group resource)
                                    :resource-display-name (rails/resource-display-name resource)))))

(defun rails/resources/filter-buffer-in-items (rails-buffer items)
  (let ((compared-file (rails/resource-buffer-file-name rails-buffer)))
    (loop for item in items
          for allow = (not (string= compared-file (rails/resource-item-file item)))
          when allow
          collect item)))

(defun rails/resources/filter-dublicated-files-in-items (items)
  (let (result deleted)
    (dolist (res-items items)
      (dolist (it res-items)
        (let* ((file (rails/resource-item-file it))
               (exist (find file result :test 'string= :key 'car)))
          (if exist
              (let* ((it-exist (cdr exist))
                     (res  (rails/resources/find (rails/resource-item-resource-type it)))
                     (eres (rails/resources/find (rails/resource-item-resource-type it-exist)))
                     (w    (rails/resource-weight res))
                     (ew   (rails/resource-weight eres)))
                (if (> w ew) ;; if weight if geater that exist weight
                    (progn
                      (delete* file result :test 'string= :key 'car) ;; remove from alist
                      (add-to-list 'deleted it-exist)                ;; place item to deleted
                      (add-to-list 'result (cons file it)))          ;; append a new item
                  (add-to-list 'deleted it)))
            (add-to-list 'result (cons file it)))))) ;; save files alist
    (setq result nil)
    (dolist (res-items items)
      (let ((its res-items))
        (dolist (del deleted)
          (setq its (remove* del its :test 'equal)))
        (when its
          (add-to-list 'result its t))))
    result))

(defun rails/resources/get-associated-items-by-resource (root rails-buffer resource &optional no-buffer-filter)
  (let ((file (rails/resource-buffer-resource-name rails-buffer))
        result name pattern-p)
    (setq result
          (progn
            (setq name file)
            ;; singularize
            (when-bind (pluralize (rails/resource-pluralize resource))
              (setq file (singularize-string file)))
            ;; pattern
            (when-bind (pattern (rails/resource-file-pattern resource))
              (setq file (replace-regexp-in-string "{name}" file pattern))
              (setq pattern-p t))
            ;; dir
            (when-bind (dir (rails/resource-dir resource))
              (setq file (concat dir file)))
            ;; file-suffix
            (when-bind (file-suffix (rails/resource-file-suffix resource))
              (setq file (concat file file-suffix)))
            ;; file-ext
            (when-bind (file-ext (rails/resource-file-ext resource))
              (setq file (concat file file-ext)))
            (if pattern-p
                (let ((dir (file-name-directory file))
                      (file (file-name-nondirectory file))
                      files)
                  (loop for it in (rails/directory-files-recursive root dir file)
                        collect (cons it (concat dir it))))
              (when (file-exists-p (concat root file))
                (list (cons name file))))))
    (setq result
          (rails/resources/resource-files-to-items resource result))
    (if no-buffer-filter
        result
      (rails/resources/filter-buffer-in-items rails-buffer result))))

(defun rails/resources/get-associated-items(root rails-buffer)
  (rails/resources/filter-dublicated-files-in-items
   (loop for res in rails/resources/list-defined
         for items = (rails/resources/get-associated-items-by-resource root rails-buffer res)
         when items
         collect items)))

(defun rails/resources/get-associated-resources(root rails-buffer)
  (loop for res in rails/resources/list-defined
        for items = (rails/resources/get-associated-items-by-resource root rails-buffer res)
        when items
        collect res))

;;; ---------------------------------------------------------
;;; - Menu functions
;;;

(defun rails/resources/items-to-menu (menu items &optional name-func)
  (let ((menu menu))
    (unless name-func
      (setq name-func 'rails/resource-item-resource-display-name))
    (dolist (it items)
      (add-to-list 'menu (cons (apply name-func (list it)) it) t))
    menu))

(defun rails/resources/find-file-by-item (root item)
  (when (rails/resource-item-p item)
    (rails/find-file root (rails/resource-item-file item))))

;;; ---------------------------------------------------------
;;; - Lookup resource by link
;;;

(defun rails/resources/linked-to-items-of-buffer(root rails-buffer)
  (let* ((type (rails/resource-buffer-type rails-buffer))
         (resource (rails/resources/find type))
         (link-to (rails/resource-link-to resource)))
    (loop for name in link-to
          with max-w   = 0
          with max-its = nil
          for res = (rails/resources/find name)
          for w   = (rails/resource-weight res)
          do (when (> w max-w)
               (when-bind (its (rails/resources/get-associated-items-by-resource root rails-buffer res))
                 (setf max-its its
                       max-w w)))
          finally (return max-its))))

(defun rails/resources/linked-items-of-buffer(root rails-buffer)
  (let* ((type (rails/resource-buffer-type rails-buffer))
         (resource (rails/resources/find type)))
    (loop for res in rails/resources/list-defined
          with max-w   = 0
          with max-its = nil
          for defined = (memq type (rails/resource-link-to res))
          for w       = (rails/resource-weight res)
          do (when (and defined (> w max-w))
               (when-bind (its (rails/resources/get-associated-items-by-resource root rails-buffer res))
                 (setf max-its its
                       max-w w)))
          finally (return max-its))))

(defun rails/resources/toggle (&optional force-ido)
  (interactive)
  (rails/with-current-buffer
   (let* ((root (rails/root))
          (resource (rails/resources/find (rails/resource-buffer-type rails/current-buffer)))
          items menu file)
     (setq items
           (if (rails/resource-link-to resource)
               (rails/resources/linked-to-items-of-buffer root rails/current-buffer)
             (rails/resources/linked-items-of-buffer root rails/current-buffer)))
     (setq menu (rails/resources/items-to-menu menu items))
     (setq file (if (< 1 (length menu))
                    (rails/display-menu "Select" menu force-ido)
                  (cdr (car menu))))
     (rails/resources/find-file-by-item root file))))

;;; ---------------------------------------------------------
;;; - Lookup resource for test
;;;

(defun rails/resources/linked-from-test-item-of-buffer (root rails-buffer)
  (let* ((type (rails/resource-buffer-type rails-buffer))
         (resource (rails/resources/find type)))
    (or
     ;; direct link
     (when-bind (test-res (rails/resources/find (rails/resource-test-to resource)))
       (when-bind (its (rails/resources/get-associated-items-by-resource
                        root
                        rails-buffer
                        test-res))
         (car its)))
     ;; test link from linked resource
     (loop for lay-name in (rails/resource-link-to resource)
           with assoc-ress  = (rails/resources/get-associated-resources root rails-buffer)
           for lay-test-to  = (rails/resource-test-to (rails/resources/find lay-name))
           for test-link    = (find lay-test-to assoc-ress :key 'rails/resource-type)
           when test-link
           return
           (car
            (rails/resources/get-associated-items-by-resource
             root
             rails-buffer
             test-link))))))

(defun rails/resources/linked-to-test-item-of-buffer (root rails-buffer)
  (let* ((type (rails/resource-buffer-type rails-buffer))
         (resource (rails/resources/find type))
         (assoc-ress (rails/resources/get-associated-resources root rails-buffer))
         test-res)
    (setq
     test-res
     (or
      ;; direct link to resource
      (loop for res in assoc-ress
            for test = (eq type (rails/resource-test-to res))
            when test
            return res)
      ;; test link to linked resource
      (loop for lay-name in (rails/resource-link-to resource)
            for test = (find lay-name assoc-ress :key 'rails/resource-test-to)
            when test
            return test)))
    (when test-res
      (car
       (rails/resources/get-associated-items-by-resource root
                                                         rails-buffer
                                                         test-res)))))

(defun rails/resources/test-buffer-p (root rails-buffer)
  "Return resource contains :test-to link, otherwise return nil."
  (let ((resource (rails/resources/find
                    (rails/resource-buffer-type rails-buffer))))
    (or
     ;; direct link
     (and (rails/resource-test-to resource) resource)
     ;; link from parent
     (loop for lay-name in (rails/resource-link-to resource)
           for lay = (rails/resources/find lay-name)
           when (rails/resource-test-to lay)
           return lay))))

(defun rails/resources/get-associated-test-item-for-buffer (root rails-buffer)
  (let ((test-res (rails/resources/test-buffer-p root rails-buffer)))
    (if test-res
        ;; it's the test, run it
        (rails/resources/get-associated-items-by-resource root
                                                          rails-buffer
                                                          test-res)
      ;; it's have the link to test
      (rails/resources/linked-to-test-item-of-buffer root
                                                     rails-buffer))))

(defun rails/resources/toggle-test ()
  (interactive)
  (rails/with-current-buffer
   (let* ((root (rails/root))
          item)
    (setq item
          (if (rails/resources/test-buffer-p root rails/current-buffer)
              (rails/resources/linked-from-test-item-of-buffer
               root
               rails/current-buffer)
            (rails/resources/linked-to-test-item-of-buffer
             root
             rails/current-buffer)))
    (rails/resources/find-file-by-item root item))))

;;; ---------------------------------------------------------
;;; - Menu for associated resources
;;;

(defun rails/resources/goto-associated-using-menu (root rails-buffer &optional resource)
  (let (items menu last-p file)
    (setq items
          (if resource
              (list
               (rails/resources/get-associated-items-by-resource root
                                                                 rails-buffer
                                                                 resource))
          (rails/resources/get-associated-items root
                                                rails-buffer)))
    (setq items
          (list-ext/group-by
           items
           '(lambda(i) (rails/resource-item-resource-menu-group (car i)))
           'string<))
    (dolist (group items)
      (let ((group-name (car group))
            (group-items (cadr group)))
        (when last-p
          (setq menu (append menu (list (cons "--" "--"))))) ;; !! dot't use add-to-list
        (dolist (i group-items)
          (if (rails/resource-expand-in-menu (rails/resources/find
                                              (rails/resource-item-resource-type
                                               (car i))))
              (setq menu (rails/resources/items-to-menu menu i 'rails/resource-item-display-name))
            (add-to-list 'menu
                         (cons (rails/resource-item-resource-display-name (car i))
                               (car i))
                         t))))
      (setq last-p t))
    (when menu
      (setq resource  (rails/resources/find (rails/resource-buffer-type rails-buffer)))
      (setq file
            (if (and resource
                     (= 1 (length menu)))
                (cdr (car menu))
              (rails/display-menu-using-popup
               (format "Go to from %s to:" (rails/resource-display-name resource))
               menu))))
    (rails/resources/find-file-by-item root file)
    file))

(defun rails/resources/goto-associated-using-ido (root rails-buffer &optional resource)
  (let (items file)
    (unless resource
      (setq resource
            (rails/display-menu-using-ido
             "Go to"
             (mapcar '(lambda(i) (cons (symbol-name (rails/resource-type i)) i))
                     (rails/resources/get-associated-resources root
                                                               rails-buffer)))))
    (setq items
          (rails/resources/get-associated-items-by-resource root
                                                            rails-buffer
                                                            resource))
    (if (< 1 (length items))
        (setq file
              (rails/display-menu-using-ido
               (format "%s" (rails/resource-display-name resource))
               (rails/resources/items-to-menu '() items)))
      (setq file (car items)))
    (rails/resources/find-file-by-item root file)
    file))

(defun rails/resources/goto-associated (&optional resource-type force-ido)
  (interactive)
  (rails/with-current-buffer
   (let ((root (rails/root))
         resource)
     (when resource-type
       (setq resource (rails/resources/find resource-type)))
     (if (and window-system
              (not force-ido)
              (eq rails/display-menu-method 'popup))
         (rails/resources/goto-associated-using-menu root rails/current-buffer resource)
       (rails/resources/goto-associated-using-ido root rails/current-buffer resource)))))

;;; ---------------------------------------------------------
;;; - Goto resource
;;;
(defun rails/resources/list-items-by-resource (root rails-buffer resource)
  (let ((dir (rails/resource-dir resource))
        (type (rails/resource-type resource))
        (comp-alist (rails/resources/get-compared-resources-alist resource))
        file-mask files item)
    (setq file-mask
          (cdr (find resource comp-alist :key 'car)))

    (setq files (rails/directory-files-recursive root dir file-mask))
    (setq files
          (loop for file in files
                for alist    = (rails/resources/compare-file-by-compared-alist (concat dir file)
                                                                               comp-alist)
                for res      = (car alist)
                for res-name = (cdr alist)
                when (eq (rails/resource-type res) type)
                collect
                (make-rails/resource-item
                 :file (concat dir file)
                 :display-name res-name
                 :resource-type (rails/resource-type resource)
                 :resource-menu-group (rails/resource-menu-group resource)
                 :resource-display-name res-name)))
    (when rails-buffer
      (setq files  (rails/resources/filter-buffer-in-items rails-buffer files)))
    (setq files (rails/resources/items-to-menu '() files))
    (setq item (rails/display-menu "File" files t))
    (rails/resources/find-file-by-item root item)))

(defun rails/resources/goto-resource (&optional resource-type)
  (interactive)
  (when-bind (root (rails/root))
    (let (resource)
      (when resource-type
        (setq resource (rails/resources/find resource-type)))
      (unless resource
        (let (items item)
          (setq items
                (loop for it in rails/resources/list-defined
                      collect (cons (symbol-name (rails/resource-type it))
                                    it)))
          (setq resource (rails/display-menu "Select resource" items t))))
      (rails/resources/list-items-by-resource root rails/current-buffer resource))))

(provide 'rails-resources)
