#lang racket

;;; filetree C-f n / C-f C-f n / C-f d：输入栏 + host IO + 刷新。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../host/event.rkt"
         "../host/final.rkt"
         "../host/layout.rkt"
         "../plugins/filetree/plugin.rkt"
         "../features/input/api.rkt")

(define root (make-temporary-directory))
(display-to-file "old" (build-path root "old.txt") #:exists 'replace)

(define engine (make-engine))
(void (engine-create-buffer! engine 1 "editor" "abc"))
(void (engine-create-view! engine 1 1))
(void (engine-create-buffer! engine 2 "*status*" ""))
(void (engine-create-view! engine 2 2))
(void (engine-create-buffer! engine 3 "*filetree*" ""))
(void (engine-create-view! engine 3 3))
(void (engine-create-buffer! engine 5 "*input*" ""))
(void (engine-create-view! engine 5 5))

(define filetree-plugin (make-filetree-plugin #:view 3 #:root root))
(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry '())
                        #:plugins (list filetree-plugin)))
(define layout (make-editor-layout #:editor-view 1
                                   #:status-views (list 2 5)
                                   #:sidebar-view 3))
(define state
  (make-app-state #:plugin-states (plugins->states (list filetree-plugin))
                  #:workspace-root (resource-normalize-path root)
                  #:area (rect 0 0 60 15)
                  #:layout layout
                  #:layout-config rebuild-layout-config
                  #:input (make-input-state #:panel-id 'status
                                            #:status-view 2
                                            #:input-view 5)))

(define s-sync (run-plugin-syncs ed state))
(define-values (s-side _a-side) (editor-focus! ed s-sync 'left))
(check-equal? (editor-focus-view-id s-side) 3)

(define (key* c) (key-event (key c)))
(define (type-text st text)
  (for/fold ([s st]) ([c (in-string text)])
    (handle-editor-event ed s (key* c))))
(define (submit st)
  (handle-editor-event ed st (key-event (key 'enter))))

;; root 行 -> 在 root 下建文件。
(engine-set-view-cursor! engine 3 0 #:column 0)
(define s-cf (handle-editor-event ed s-side (key-event (key 'f 'ctrl))))
(define s-new (handle-editor-event ed s-cf (key-event (key 'n))))
(check-true (editor-input-active? s-new))
(define s-typed (type-text s-new "new.txt"))
(define s-created (submit s-typed))
(check-false (editor-input-active? s-created))
(check-true (file-exists? (build-path root "new.txt")))

;; C-f C-f n：建目录。
(define s-sync2 (run-plugin-syncs ed s-created))
(engine-set-view-cursor! engine 3 0 #:column 0)
(define s-cf1 (handle-editor-event ed s-sync2 (key-event (key 'f 'ctrl))))
(define s-cf2 (handle-editor-event ed s-cf1 (key-event (key 'f 'ctrl))))
(define s-dir-prompt (handle-editor-event ed s-cf2 (key-event (key 'n))))
(check-true (editor-input-active? s-dir-prompt))
(define s-dir-typed (type-text s-dir-prompt "newdir"))
(define s-dir-created (submit s-dir-typed))
(check-true (directory-exists? (build-path root "newdir")))

;; C-f d：删除 new.txt。
(define s-sync3 (run-plugin-syncs ed s-dir-created))
(define rows (filetree-state-rows (editor-state-plugin-state s-sync3 'filetree)))
(define file-line
  (for/first ([row (in-list rows)] [i (in-naturals)]
              #:when (equal? (car row) (build-path root "new.txt")))
    i))
(check-not-false file-line)
(engine-set-view-cursor! engine 3 file-line #:column 0)
(define s-del-cf (handle-editor-event ed s-sync3 (key-event (key 'f 'ctrl))))
(define s-del-prompt (handle-editor-event ed s-del-cf (key-event (key 'd))))
(check-true (editor-input-active? s-del-prompt))
(define s-yes (type-text s-del-prompt "y"))
(define s-deleted (submit s-yes))
(check-false (file-exists? (build-path root "new.txt")))

(define s-sync4 (run-plugin-syncs ed s-deleted))
(check-false (string-contains? (engine-view-text engine 3) "new.txt"))

(delete-directory/files root)
(displayln "edit-tui-rebuild/test/filetree-io.rkt: ok")
