#lang racket

;;; edit-tui/source/model.rkt —— 解析来源的纯值模型
;;;
;;; 解析层只消费 source-snapshot，不关心文本来自 buffer 还是磁盘。
;;;
;;;   source-id       身份：(kind . value)
;;;   authority       当前权威：buffer | disk | virtual
;;;   version         缓存失效键
;;;   path            规范化绝对路径；virtual / 无 path buffer 为 #f
;;;   text            当前快照
;;;
;;; 不变量：
;;;   · disk source 必须有 path；
;;;   · buffer / virtual 可以没有 path；
;;;   · source-id 的 kind 与 snapshot authority 一致；
;;;   · 同一 path 的优先级由 source-store 决定，model 不处理。
;;;
;;; 本模块不读 IO、不 require app / boot / core。

(provide (struct-out source-id)
         (struct-out source-snapshot)
         disk-source-id-for-path
         buffer-source
         disk-source
         virtual-source
         source-normalize-path
         source-snapshot-cache-key)

(require racket/path)

(struct source-id
  (kind     ; 'buffer | 'disk | 'virtual
   value)   ; buffer did / 规范化 path / virtual id
  #:transparent)

(struct source-snapshot
  (id
   path        ; 规范化绝对路径字符串 | #f
   authority   ; 'buffer | 'disk | 'virtual
   version     ; 任意可比较 token
   text)       ; 当前全文
  #:transparent)

;; path 统一成规范化绝对路径字符串。传入 #f 时保持 #f（buffer/virtual 可无 path）。
(define (source-normalize-path p)
  (and p
       (let ([path (cond [(path? p) p]
                         [(string? p) (string->path p)]
                         [else (raise-argument-error
                                'source-normalize-path
                                "(or/c #f string? path?)"
                                p)])])
         (path->string (simplify-path (path->complete-path path))))))

;; disk source 的身份完全由规范化 path 决定。
(define (disk-source-id-for-path p)
  (define path* (source-normalize-path p))
  (unless path*
    (raise-argument-error 'disk-source-id-for-path "non-empty path" p))
  (source-id 'disk path*))

(define (check-source-owner who id)
  (unless id
    (raise-argument-error who "non-#f id" id)))

(define (buffer-source id path text #:version [version #f])
  (check-source-owner 'buffer-source id)
  (source-snapshot (source-id 'buffer id)
                   (source-normalize-path path)
                   'buffer
                   (or version text)
                   text))

(define (disk-source path text #:version [version #f])
  (define path* (source-normalize-path path))
  (unless path*
    (raise-argument-error 'disk-source "non-empty path" path))
  (source-snapshot (source-id 'disk path*)
                   path*
                   'disk
                   (or version text)
                   text))

(define (virtual-source id text #:version [version #f])
  (check-source-owner 'virtual-source id)
  (source-snapshot (source-id 'virtual id)
                   #f
                   'virtual
                   (or version text)
                   text))

;; 分析缓存键：身份 + 版本。不要只用 path，避免 buffer/disk 切换混缓存。
(define (source-snapshot-cache-key snapshot)
  (list (source-snapshot-id snapshot)
        (source-snapshot-version snapshot)))
