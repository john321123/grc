;; -*- lexical-binding: t -*-
;;; grc-req.el --- Google Reader Mode for Emacs
;;
;; Copyright (c) 2011 David Leatherman
;;
;; Author: David Leatherman <leathekd@gmail.com>
;; URL: http://www.github.com/leathekd/grc
;; Version: 0.1.0

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This file contains code for getting and posting from and to Google

;;; License:

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Code:
(require 'json)
(require 'oauth2)

(defvar grc-req-client-name "grc-emacs-client"
  "Arbitrary client string for various reqeuests")

(defvar grc-auth-header-format
  "--header 'Authorization: OAuth %s'"
  "HTTP authorization headers to send.")

(defvar grc-req-base-url "http://www.google.com/reader/"
  "Base URL for Google Reader  API.")

(defvar grc-req-edit-tag-url
  (concat grc-req-base-url "api/0/edit-tag")
  "URL for editing a tag")

(defvar grc-req-curl-options (concat "--compressed --silent"
                                     " --location --location-trusted"
                                     " --connect-timeout 2 --max-time 10"
                                     " --retry 1"))

(defun grc-req-stream-url (&optional state)
  "Get the url for Google Reader entries, optionally limited to a specified
  state- e.g., kept-unread"
  (let ((stream-state (if (null state)
                          ""
                        (concat "user/-/state/com.google/" state))))
    (format "http://www.google.com/reader/api/0/stream/contents/%s"
            stream-state)))

(defvar grc-req-reading-list-url (grc-req-stream-url "reading-list"))

(defun grc-req-parse-response (raw-resp)
  (cond
   ((string-match "^{" raw-resp)
    (grc-parse-parse-response
     (let ((json-array-type 'list))
       (json-read-from-string
        (decode-coding-string raw-resp 'utf-8)))))
   ((string-match "^OK" raw-resp)
    "OK")
   (t nil)))

(defun grc-req-format-url-params (params)
  "Convert an alist of params into an & delimeted string suitable for curl"
  (mapconcat
   (lambda (p)
     (cond
      ((consp p)
       (concat (format "%s" (car p))
               "="
               (url-hexify-string (format "%s" (cdr p)))))
      (t
       (url-hexify-string (format "%s" p)))))
   params "&"))

(defun grc-req-request (url callback &optional
                            method params post-body headers retry-count)
  (setq grc-token (or grc-token (grc-auth)))
  (let ((grapnel-options grc-req-curl-options)
        (failure-cb
         (lambda (resp resp-hdrs)
           ;; try reauthenticating
           (if (> (or retry-count 0) 2)
               (error "Failed with: %s for %s"
                      (cadr (assoc "response-code" resp-hdrs))
                      url)
             (if (cdr (assoc "X-Reader-Google-Bad-Token" resp-hdrs))
                 (grc-refresh-action-token
                  (lambda ()
                    (grc-req-request url callback method
                                         params post-body headers
                                         (1+ (or retry-count 0)))))
               (grc-refresh-access-token
                (lambda ()
                  (grc-req-request url callback method
                                       params post-body headers
                                       (1+ (or retry-count 0))))))))))
    (grapnel-retrieve-url
     url
     `((success . ,callback)
       (failure . ,failure-cb)
       (error . (lambda (resp exit-code) (error "Error: %s %s"
                                           response exit-code))))
     method
     (append params
             `((client . ,grc-req-client-name)
               (ck . ,(grc-string (floor
                                   (* 1000000 (float-time)))))
               (output . "json")))
     post-body
     (append
      `(("Authorization" . ,(format "OAuth %s"
                                    (plist-get grc-token :access-token))))
      headers))))

(defun grc-req-fetch-entries (state callback &optional limit since addl-params)
  (let* (;; the number of items to return
         (params `(("n" . ,(format "%s" (or limit grc-fetch-count)))))
         (params (append params addl-params))
         ;; the oldest in which I'm interested
         (params (if since
                     (cons `("ot" . ,(format "%s" since)) params)
                   params)))
    (grc-req-request (grc-req-stream-url state) callback
                     "GET"
                     (append params
                             `(;; ranking method- newest first
                               ("r" . "n"))))))

(defun grc-req-unread-entries (state callback &optional limit since)
  (grc-req-fetch-entries state callback limit since
                         `(;; exclude read entries
                           ("xt" . "user/-/state/com.google/read"))))

(defun grc-req-mark (ids feeds params)
  (let ((params (append params
                        `(("T" . ,(plist-get grc-token :action-token)))
                        (mapcar (lambda (i) `("i" . ,i)) ids)
                        (mapcar (lambda (s) `("s" . ,s)) feeds))))
    (grc-req-request grc-req-edit-tag-url '(lambda (&rest x))
                     "POST" nil params
                     (list '("Content-Type" .
                             "application/x-www-form-urlencoded")))))

(defun grc-req-mark-kept-unread (ids feeds)
  "Send a request to mark an entry as kept-unread.  Will also remove the read
  category"
  (grc-req-mark ids feeds '(("a" . "user/-/state/com.google/kept-unread")
                            ("r" . "user/-/state/com.google/read"))))

(defun grc-req-mark-read (ids feeds)
  "Send a request to mark an entry as read.  Will also remove the kept-unread
  category"
  (grc-req-mark ids feeds '(("r" . "user/-/state/com.google/kept-unread")
                            ("a" . "user/-/state/com.google/read"))))

(defun grc-req-mark-starred (ids feeds &optional remove-p)
  (grc-req-mark ids feeds
                `(((if remove-p "r" "a") . "user/-/state/com.google/starred"))))

(defun grc-req-unread-count (callback)
  (grc-req-request
   "https://www.google.com/reader/api/0/unread-count"
   (lambda (response headers)
     (let* ((json-array-type 'list))
       (with-current-buffer grc-list-buffer
         (funcall callback
                  (or (car (sort
                            (->> (json-read-from-string
                                  (decode-coding-string response 'utf-8))
                              (assoc 'unreadcounts)
                              (cdr)
                              (mapcar (lambda (x) (cdr (assoc 'count x)))))
                            '>))
                      0)))))))

(provide 'grc-req)
;;; grc-req.el ends here
