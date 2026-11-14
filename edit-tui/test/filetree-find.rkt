#lang racket

;;; filetree 查找：
;;;   · C-f s 打开 Find file 输入栏
;;;   · 查找结果不覆盖文件树：展开匹配路径的祖先目录，光标落到对应行
;;;   · 查询是一次性的；之后的展开 / 折叠 / 刷新不会被查找重跑覆盖
;;;   · C-left / C-right 在匹配项之间移动并定位
;;;   · Enter 文件 -> open-file-action；Esc 只清查找会话，树保持原样
;;;   · 异步路径：search job -> 展开 + cursor，再由普通 tree scan 投影

(require rackunit
         racket/async-channel
         racket/file
         racket/path
         racket/string
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../core/job/api.rkt"
         "../host/event.rkt"
         "../edit.rkt"
         "../host/jobs.rkt"
         "../app/layout.rkt"
         "../features/input/api.rkt"
         "../features/placement/api.rkt"
         "../plugins/filetree/plugin.rkt")

(define root (make-temporary-directory))

(define (touch rel)
  (define p (build-path root rel))
  (make-parent-directory* p)
  (display-to-file "" p #:exists 'replace)
  p)

(void (touch "alpha.txt"))
(void (touch "other/alpha2.txt"))
(void (touch "dir/beta.rkt"))
(void (touch "dir/nested/gamma.txt"))
(void (touch ".hidden.txt"))

(define (make-app)
  (define-values (ed state)
    (make-editor-app #:workspace-root root
                     #:initial-name "test.rkt"
                     #:initial-text "#lang racket\n"
                     #:initial-resource? #t))
  (values ed (run-plugin-syncs ed (state-with-screen state (rect 0 0 80 24)))))

(define (key-event* name . mods)
  (key-event (apply key name mods)))

(define (press ed s name . mods)
  (handle-editor-event ed s (apply key-event* name mods)))

(define (type-text ed s text)
  (for/fold ([s s]) ([c (in-string text)])
    (handle-editor-event ed s (key-event (key c)))))

(define (focus-filetree ed s)
  (define-values (s* _actions) (editor-focus! ed s 'left))
  (check-eq? (editor-focus-panel-kind s*) 'sidebar)
  s*)

(define (start-search ed s query)
  (define s1 (press ed s 'f 'ctrl))
  (define s2 (press ed s1 's))
  (check-true (editor-input-active? s2))
  (check-eq? (editor-input-kind s2) 'filetree-find)
  ;; C-f s 会预填上次 query；先清空再输入本次 query。
  (define s3
    (for/fold ([s s2]) ([_ (in-range (string-length (or (editor-input-text s2) "")))])
      (press ed s 'backspace)))
  (define s4 (type-text ed s3 query))
  (press ed s4 'enter))

(define (ps-of s) (state-plugin-state s 'filetree))
(define (rows-of s) (filetree-state-rows (ps-of s)))

(define (line-of-path s path)
  (for/first ([row (in-list (rows-of s))] [i (in-naturals)]
              #:when (equal? (car row) path))
    i))

;;; ════════════════ 查找 + 打开文件 ════════════════

(define-values (ed s0) (make-app))
(define sf (focus-filetree ed s0))
(define s-search (start-search ed sf "alpha"))
(check-false (editor-input-active? s-search))

(define s1 (run-plugin-syncs ed s-search))
(define ps1 (ps-of s1))
(check-true (filetree-state? ps1))
(check-equal? (filetree-state-find-query ps1) "alpha")
(check-equal? (length (filetree-state-find-matches ps1)) 2)
(check-false (filetree-state-find-truncated? ps1))

;; 树没有被查找结果覆盖：仍是 root / 目录 / 文件结构。
(check-equal? (car (rows-of s1)) (list root 'root (path->string root) 0))
(define alpha-path (build-path root "alpha.txt"))
(check-equal? (cadr (list-ref (rows-of s1)
                                 (line-of-path s1 alpha-path)))
              'file)
;; 第一条匹配在 root 下，光标就是 alpha.txt 行。
(check-equal? (editor-view-point-line ed 3) (line-of-path s1 alpha-path))
(check-true (string-contains? (engine-view-text (editor-engine ed) 3)
                              (path->string root)))

;; Enter 文件 -> placement，目标 path 正确。
(define s-open (press ed s1 'enter))
(check-true (editor-placement-active? s-open))
(define pvid (editor-placement-view-id s-open))
(define r (state-resource-for-view s-open pvid))
(check-not-false r)
(check-equal? (resource-path r)
              (resource-normalize-path alpha-path))

;;; ════════════════ C-left / C-right：匹配项导航 ════════════════

(define-values (edn sn0) (make-app))
(define sfn (focus-filetree edn sn0))
(define sn1 (run-plugin-syncs edn (start-search edn sfn "alpha")))
(define other-path (build-path root "other/alpha2.txt"))
(check-equal? (filetree-state-find-index (ps-of sn1)) 0)
(check-equal? (editor-view-point-line edn 3) (line-of-path sn1 alpha-path))

;; C-right -> 第二条匹配；other 目录展开，光标移到 alpha2.txt。
(define sn2 (run-plugin-syncs edn (press edn sn1 'right 'ctrl)))
(check-equal? (filetree-state-find-index (ps-of sn2)) 1)
(check-equal? (editor-view-point-line edn 3) (line-of-path sn2 other-path))
(check-true (string-contains? (engine-view-text (editor-engine edn) 3)
                              "alpha2.txt"))

;; C-left -> 回到第一条匹配；other 的展开状态保留，不被搜索重置。
(define sn3 (run-plugin-syncs edn (press edn sn2 'left 'ctrl)))
(check-equal? (filetree-state-find-index (ps-of sn3)) 0)
(check-equal? (editor-view-point-line edn 3) (line-of-path sn3 alpha-path))
(check-true (string-contains? (engine-view-text (editor-engine edn) 3)
                              "alpha2.txt"))

;;; ════════════════ 查找后目录仍可折叠 ════════════════

(define-values (edc sc0) (make-app))
(define sfc (focus-filetree edc sc0))
(define sc1 (run-plugin-syncs edc (start-search edc sfc "nested")))
(define dir-path (build-path root "dir"))
(define gamma-path (build-path root "dir/nested/gamma.txt"))
(check-equal? (editor-view-point-line edc 3)
              (line-of-path sc1 (build-path root "dir/nested")))

;; 把光标移到 dir 行并折叠它：查找不能把展开状态锁回去。
(engine-set-view-cursor! (editor-engine edc) 3
                         (line-of-path sc1 dir-path) #:column 0)
(define sc2 (run-plugin-syncs edc (press edc sc1 'enter)))
(check-false (string-contains? (engine-view-text (editor-engine edc) 3)
                               "nested"))
(check-equal? (length (filetree-state-find-matches (ps-of sc2))) 2)

;; C-right -> 第二条匹配 gamma.txt，重新展开到它并定位。
(define sc3 (run-plugin-syncs edc (press edc sc2 'right 'ctrl)))
(check-equal? (filetree-state-find-index (ps-of sc3)) 1)
(check-equal? (editor-view-point-line edc 3) (line-of-path sc3 gamma-path))
(check-true (string-contains? (engine-view-text (editor-engine edc) 3)
                              "gamma.txt"))

;;; ════════════════ 目录匹配：展开并定位 ════════════════

(define-values (ed2 s20) (make-app))
(define sf2 (focus-filetree ed2 s20))
(define s2-search (start-search ed2 sf2 "nested"))
(define s2a (run-plugin-syncs ed2 s2-search))
(define nested-path (build-path root "dir/nested"))
(define nested-line (line-of-path s2a nested-path))
(check-not-false nested-line)
(check-equal? (editor-view-point-line ed2 3) nested-line)
;; 只展开到匹配目录；它下面的 gamma.txt 仍然折叠。
(check-true (string-contains? (engine-view-text (editor-engine ed2) 3)
                              "nested"))
(check-false (string-contains? (engine-view-text (editor-engine ed2) 3)
                               "gamma.txt"))

;;; ════════════════ Esc：只清查找会话，树保持原样 ════════════════

(define-values (ed3 s30) (make-app))
(define sf3 (focus-filetree ed3 s30))
(define beta-path (build-path root "dir/beta.rkt"))
(define s3-search (start-search ed3 sf3 "beta"))
(define s3a (run-plugin-syncs ed3 s3-search))
(check-equal? (editor-view-point-line ed3 3)
              (line-of-path s3a beta-path))

(define s3b (press ed3 s3a 'escape))
(define s3c (run-plugin-syncs ed3 s3b))
(check-equal? (filetree-state-find-query (ps-of s3c)) #f)
;; 查找展开的 dir 仍在树里，光标仍在 beta.rkt。
(check-true (string-contains? (engine-view-text (editor-engine ed3) 3)
                              "beta.rkt"))
(check-equal? (editor-view-point-line ed3 3)
              (line-of-path s3c beta-path))

;;; ════════════════ 隐藏文件：C-h 不重跑旧查询 ════════════════

(define hidden-path (build-path root ".hidden.txt"))
(define s4-search (start-search ed3 s3c "hidden"))
(define s4a (run-plugin-syncs ed3 s4-search))
(check-equal? (filetree-state-find-matches (ps-of s4a)) '())
(check-false (string-contains? (engine-view-text (editor-engine ed3) 3)
                               ".hidden.txt"))

;; C-h 只改变树，不重跑一次性查询。
(define s4b (run-plugin-syncs ed3 (press ed3 s4a 'h 'ctrl)))
(check-equal? (filetree-state-find-matches (ps-of s4b)) '())
(check-true (string-contains? (engine-view-text (editor-engine ed3) 3)
                              ".hidden.txt"))

;; 新的查找才会匹配 hidden 文件。
(define s4c (run-plugin-syncs ed3 (start-search ed3 s4b "hidden")))
(check-equal? (length (filetree-state-find-matches (ps-of s4c))) 1)
(check-equal? (editor-view-point-line ed3 3)
              (line-of-path s4c hidden-path))

;;; ════════════════ 异步查找 job ════════════════

(define root2 (make-temporary-directory))
(define async-target (build-path root2 "dir/async-alpha.txt"))
(make-parent-directory* async-target)
(display-to-file "" async-target #:exists 'replace)

(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test" ""))
(void (engine-create-view! engine 1 1))
(void (engine-create-buffer! engine 3 "*filetree*" "" #:kind 'ui))
(void (engine-create-view! engine 3 3))

(define plugin (make-filetree-plugin #:view 3 #:root root2))
(define ed4 (make-editor #:engine engine
                         #:registry (make-hook-registry '())
                         #:plugins (list plugin)))
(define layout (make-editor-layout #:editor-view 1 #:sidebar-view 3))
(define state4
  (make-app-state #:plugin-states (plugins->states (list plugin))
                  #:screen (rect 0 0 60 15)
                  #:layout layout
                  #:async? #t))

;; 先把普通树扫描完，确保后面只有 search job。
(define s5 (run-plugin-syncs ed4 state4))
(define event-channel (make-async-channel))
(define rt (start-job-runtime (editor-services ed4)
                              #:event-channel event-channel
                              #:workers 1))
(dispatch-jobs! rt (state-jobs s5))
(define scan-ev (async-channel-get event-channel))
(check-eq? (job-result-event-kind scan-ev) 'filetree-scan)
(define s6 (handle-job-result ed4 s5 scan-ev))
(define s6b (run-plugin-syncs ed4 s6))

;; 提交查找：只出现一个 search job。
(define ps4 (filetree-find-submit! (state-plugin-state s6b 'filetree)
                                   "async-alpha"))
(define state4b (state-set-plugin-state s6b 'filetree ps4))
(define s7 (run-plugin-syncs ed4 state4b))
(define search-jobs
  (filter (λ (j) (eq? (job-kind j) 'filetree-search))
          (state-pending-jobs s7)))
(check-equal? (length search-jobs) 1)

(dispatch-jobs! rt (state-jobs s7))
(define search-ev (async-channel-get event-channel))
(stop-job-runtime rt)
(check-eq? (job-result-event-kind search-ev) 'filetree-search)

(define s8 (handle-job-result ed4 s7 search-ev))
(define ps8 (state-plugin-state s8 'filetree))
(check-equal? (filetree-state-find-matches ps8) (list async-target))
(check-equal? (filetree-state-find-index ps8) 0)
(check-true (hash-ref (filetree-state-expanded ps8)
                      (build-path root2 "dir") #f))
(check-equal? (filetree-state-pending-cursor ps8) async-target)

(delete-directory/files root2)
(delete-directory/files root)

(displayln "edit-tui/test/filetree-find.rkt: ok")
