#lang racket

;;; edit-tui/test/lang-word-pool.rkt —— 光标前词 + 补全候选的“内存优先”
;;;
;;; 覆盖：
;;;   1. word-before：只取光标左侧连续词字符（补全前缀 / 文档查询共用）；
;;;   2. require 本地文件时：打开的 buffer 优先于磁盘模块（即使磁盘内容不同）；
;;;   3. (file "...") spec 与普通字符串 spec 走同一套内存/磁盘选择；
;;;   4. spec-binding-of 也用同一个来源，所以文档不会指向磁盘上的旧导出。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../plugins/lang/word.rkt"
         "../plugins/lang/source.rkt"
         "../plugins/lang/pool.rkt")

;;; ════════════════ 1. word-before ════════════════

(check-equal? (word-before "abc def" 0 3) "abc")
(check-equal? (word-before "abc def" 0 4) "")
(check-equal? (word-before "abc def" 0 7) "def")
(check-equal? (word-before "abc-def" 0 4) "abc-")
(check-equal? (word-before "(square x)" 0 7) "square")
(check-equal? (word-before "abc" 0 99) "abc")          ; col 越界 -> 行尾
(check-equal? (word-before "abc" 9 1) "")              ; line 越界 -> 空行
(check-equal? (word-before "" 0 0) "")

;;; ════════════════ 2. 顶层定义扫描（不依赖展开，覆盖常见绑定形式） ════════════════

(define defs-text
  (string-join
   '("#lang racket"
     ""
     "(define/contract (f x) (-> integer? integer?) x)"
     "(struct point (x y) #:mutable)"
     "(define-struct old (a b))"
     "(define-values (u v) (values 1 2))"
     "(define-syntaxes (m1 m2) (values 1 2))"
     "(define/match (g x) [(_ 0) 0] [(_ n) n])")
   "\n"))
(define-values (_defs-lang defs-forms) (module-context defs-text))
(define defs (definitions-of-forms defs-forms))
(for ([name (in-list '(f point point? point-x point-y set-point-x! set-point-y!
                         make-old old? old-a set-old-a! u v m1 m2 g))])
  (check-not-false (memq name defs) (format "scanner 漏了 ~a" name)))

;; provide (struct-out …) 也包含访问器（打开的本地模块优先用这条路径）
(define provides
  (provides-of-forms "#lang racket\n(struct point (x y))\n(provide (struct-out point))\n"))
(for ([name (in-list '("point" "point?" "point-x" "point-y"))])
  (check-not-false (member name provides) (format "scanner provide 漏了 ~a" name)))

;;; ════════════════ 3. 本地 require：内存优先于磁盘 ════════════════

(define dir (make-temporary-file "edit-tui-pool-~a" 'directory))
(define file (build-path dir "helper.rkt"))
(define abs (path->string (path->complete-path file)))

(display-to-file "#lang racket\n(provide disk-name)\n(define disk-name 1)\n"
                 file #:exists 'truncate)

;; 没有打开文档 -> 读磁盘模块
(check-equal? (sort (spec-names "helper.rkt" dir) string<?) '("disk-name"))
(check-equal? (sort (spec-names (list 'file abs) dir) string<?) '("disk-name"))

;; 同一路径在内存里打开（内容还没保存）-> 用 buffer 的 provide，不读磁盘
(define open (hash abs "#lang racket\n(provide memory-name)\n"))
(check-equal? (spec-names "helper.rkt" dir open) '("memory-name"))
(check-equal? (spec-names (list 'file abs) dir open) '("memory-name"))
(check-false (member "disk-name" (spec-names "helper.rkt" dir open)))

;; 文档的来源反查也以内存为准
(check-equal? (spec-binding-of "memory-name" (list "helper.rkt") dir open)
              (list (local-file-path file) "memory-name"))
(check-false (spec-binding-of "disk-name" (list "helper.rkt") dir open))

;; 相对路径带 ".."：open-map 的 key 与 module 查询都必须归一到同一个绝对路径。
;; （否则内存里的新 provide 会被当成磁盘旧模块，补全 / 文档都找不到目标。）
(define sub (build-path dir "sub"))
(make-directory* sub)
(check-equal? (module-path-key (build-path sub ".." "helper.rkt"))
              (module-path-key file))
(define open-messy (hash (module-path-key file)
                         "#lang racket\n(provide memory-name)\n"))
(check-equal? (spec-names "../helper.rkt" sub open-messy) '("memory-name"))
(check-equal? (spec-names (list 'file
                                (path->string (build-path sub ".." "helper.rkt")))
                          sub open-messy)
              '("memory-name"))

;; 清理（磁盘模块编译出的 compiled/ 也在临时目录里）
(delete-directory/files dir)

(displayln "edit-tui lang-word-pool: ok")
