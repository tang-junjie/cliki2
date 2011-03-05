;;;; auth.lisp

(in-package #:cliki2)

(defun pack-auth-cookie (name password &key (version 1) (date (get-universal-time)))
  (format nil "~A|~A|~A|~A" version name password date))

(defun encrypt-auth-cookie (name password &key (version 1) (date (get-universal-time)))
  (let ((result (ironclad:ascii-string-to-byte-array
                 (pack-auth-cookie name password :version version :date date))))
    (ironclad:encrypt-in-place *user-auth-cipher*
                               result)
    (ironclad:byte-array-to-hex-string result)))

(defun set-auth-cookie (name password &key (version 1))
  (hunchentoot:set-cookie *cookie-auth-name*
                          :value (encrypt-auth-cookie name password :version version)
                          :path "/"
                          :expires (+ (get-universal-time) (* 60 60 24 4))
                          :http-only t))

;;;; get-auth-cookie

(defun unpack-auth-cookie (str)
  (let ((info (split-sequence:split-sequence #\| str)))
    (values (first info)
            (second info)
            (third info)
            (fourth info))))

(defun hex-string-to-byte-array (string &key (start 0) (end nil))
  (declare (type string string))
  (let* ((end (or end (length string)))
         (length (/ (- end start) 2))
         (key (make-array length :element-type '(unsigned-byte 8))))
    (declare (type (simple-array (unsigned-byte 8) (*)) key))
    (flet ((char-to-digit (char)
             (let ((x (position char "0123456789abcdef" :test #'char-equal)))
               (or x (error "Invalid hex key ~A specified" string)))))
      (loop for i from 0
            for j from start below end by 2
            do (setf (aref key i)
                     (+ (* (char-to-digit (char string j)) 16)
                        (char-to-digit (char string (1+ j)))))
         finally (return key)))))

(defun decrypt-auth-cookie (str)
  (ignore-errors
    (let ((result (hex-string-to-byte-array str)))
      (ironclad:decrypt-in-place *user-auth-cipher*
                                 result)
      (unpack-auth-cookie (babel:octets-to-string result :encoding :utf-8)))))

(defun get-auth-cookie ()
  (let ((cookie (hunchentoot:cookie-in *cookie-auth-name*)))
    (if cookie
        (decrypt-auth-cookie cookie))))

;;; compute-user-login-name

(defclass check-auth-user-route (routes:proxy-route) ())

(defun check-user-auth ()
  (multiple-value-bind (version name password date) (get-auth-cookie)
    (if (and version name password date)
        (let ((user (user-with-name name)))
          (if (and user
                   (string= (user-password user)
                            password))
              user)))))
        
(defmethod routes:route-check-conditions ((route check-auth-user-route) bindings)
  (let ((*user* (check-user-auth)))
    (call-next-method)))

(defmethod restas:process-route ((route check-auth-user-route) bindings)
  (let ((*user* (check-user-auth)))
    (call-next-method)))

(defun @check-auth-user (origin)
  (make-instance 'check-auth-user-route :target origin))

(defun password-cache (password)
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence :md5
                             (babel:string-to-octets password :encoding :utf-8))))

(defun run-sing-in (user &key (version 1))
  "Set cookie for user name and password"
  (set-auth-cookie (user-name user)
                   (user-password user)
                   :version version))

(defun run-sing-out ()
  "Clear cookie with auth information"
  (hunchentoot:set-cookie *cookie-auth-name*
                          :value ""
                          :path "/"))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; routes
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(restas:define-route sign-out ("specials/singout")
  (run-sing-out)
  ;;(setf *user* nil)
  (restas:redirect (hunchentoot:referer)))


(restas:define-route sign-in ("specials/singin")
  :sign-in-page)

(restas:define-route sign-in/post ("specials/singin"
                                   :method :post
                                   :requirement 'not-sign-in-p)
  (let* ((name (hunchentoot:post-parameter "name"))
         (password (password-cache (hunchentoot:post-parameter "password")))
         (done (hunchentoot:get-parameter "done"))
         (user (user-with-name name)))
    (cond
      ((and user (string= (user-password user) password))
       (run-sing-in user)
       (restas:redirect (or done "/")))
      (t (restas:redirect 'sign-in)))))
       
(restas:define-route register ("specials/register")
  (make-instance 'register-page))

(defun form-field-value (field)
  (hunchentoot:post-parameter field))

(defun form-field-empty-p (field)
  (string= (form-field-value field)
           ""))

(defparameter *re-email-check* 
  "^[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*@(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$")

(defun check-register-form ()
  (let ((bads nil))
    (flet ((form-error-message (field message)
             (push message bads)
             (push field bads)))
      (cond
        ((form-field-empty-p "name")
         (form-error-message :bad-name "empty"))
        ((user-with-name (form-field-value "name"))
         (form-error-message :bad-name "exist")))
      
      (cond
        ((form-field-empty-p "email") (form-error-message :bad-email "empty"))
        ((not (ppcre:scan *re-email-check*
                          (string-downcase (form-field-value "email"))))
         (form-error-message :bad-email
                             "bad"))
        ((user-with-email (form-field-value "email"))
         (form-error-message :bad-email
                             "exist")))

      (cond
        ((form-field-empty-p "password")
         (form-error-message :bad-password
                             "empty"))
        ((< (length (form-field-value "password")) 8)
         (form-error-message :bad-password
                             "short")))
      
      (unless (string= (form-field-value "password")
                       (form-field-value "re-password"))
        (form-error-message :bad-re-password
                            "bad"))

      (unless (cl-recaptcha:verify-captcha (hunchentoot:post-parameter "recaptcha_challenge_field")
                                           (hunchentoot:post-parameter "recaptcha_response_field")
                                           (hunchentoot:real-remote-addr)
                                           :private-key *reCAPTCHA.privake-key*)
        (form-error-message :bad-recaptcha "Bad")))
    
      bads))

(restas:define-route register/post ("specials/register"
                                    :method :post
                                    :requirement 'not-sign-in-p)
  (let ((fails (check-register-form))
        (nickname (form-field-value "name"))
        (email (form-field-value "email"))
        (password (form-field-value "password")))
    (cond
      (fails
       (make-instance 'register-page
                      :data (list* :name nickname
                                   :email email
                                   :password password
                                   :re-password (form-field-value "re-password")
                                   fails)))
      (t (let ((invite (with-transaction ()
                         (make-instance 'invite
                                        :user (make-instance 'user
                                                             :name nickname
                                                             :email email
                                                             :password (password-cache password)
                                                             :role :invite))))
               (to (list email)))
           (sendmail to
                     (cliki2.view:confirmation-mail 
                      (list :to to
                            :noreply-mail *noreply-email*
                            :subject (prepare-subject "Потверждение регистрации")
                            :host (hunchentoot:host)
                            :link (restas:gen-full-url 'accept-invitation
                                                       :mark (invite-mark invite)))))
           :register-sendmail-page)))))

(restas:define-route confirm-registration ("specials/invite/:mark"
                                           :requirement 'not-sign-in-p)
  (let ((invite (invite-with-mark mark)))
    (unless invite
      (restas:abort-route-handler hunchentoot:+http-not-found+))
    :confirm-registration-page))

(restas:define-route confirm-registration/post ("specials/invite/:mark"
                                                :method :post
                                                :requirement 'not-sign-in-p)
  (let ((invite (invite-with-mark mark)))
    (unless invite
      (restas:abort-route-handler hunchentoot:+http-not-found+))
    
    (with-transaction ()
      (setf (user-role (invite-user invite))
            nil)
      (delete-object invite))

    (restas:redirect 'entry)))
   