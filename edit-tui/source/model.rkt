#lang racket

;;; edit-tui/source/model.rkt —— 解析来源的纯值模型
;;;
;;; 解析层不直接关心“文本来自 buffer 还是磁盘”，只看 source-snapshot：
;;;
;;;   source-id       身份（buffer did / disk path / virtual id）
;;;   authority       谁是真值：buffer | disk | virtual
;;;   version         缓存失效键（buffer document version / disk stamp / virtual version）
;;;   text            当前快照
;;;
;;; buffer / virtual 是内存权威；disk 是外部权威。
;;; 同一路径的优先级由 source-store 统一决定：buffer > disk。
;;;
;;; 本模块不读 IO、不 require app / boot / core。

(provide (struct-out source-id)
         (struct-out source-snapshot)
         source-id-for-path
         buffer-source
         disk-source
         virtual-source
         source-normalize-path
         source-snapshot-key
         source-snapshot-path-key)

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

(define (source-normalize-path p)
  (and p
       (let ([path (cond [(path? p) p]
                         [(string? p) (string->path p)]
                         [else (error 'source-normalize-path "path 要是 string/path：~a" p)])])
         (path->string (simplify-path (path->complete-path path))))))

(define (source-id-for-path p)
  (define path* (source-normalize-path p))
  (and path* (source-id 'disk path*)))

(define (buffer-source id path text #:version [version #f])
  (source-snapshot (source-id 'buffer id)
                   (source-normalize-path path)
                   'buffer
                   (or version text)
                   text))

(define (disk-source path text #:version [version #f])
  (define path* (source-normalize-path path))
  (source-snapshot (source-id 'disk path*)
                   path*
                   'disk
                   (or version text)
                   text))

(define (virtual-source id text #:version [version #f])
  (source-snapshot (source-id 'virtual id)
                   #f
                   'virtual
                   (or version text)
                   text))

;; 分析缓存键：身份 + 版本。不要只用 path，避免 buffer/disk 切换混缓存。
(define (source-snapshot-key snapshot)
  (list (source-snapshot-id snapshot)
        (source-snapshot-version snapshot)))

;; path 维度只用于索引/显示；同一 path 可能短暂同时存在 buffer 和 disk 快照。
(define (source-snapshot-path-key snapshot)
  (source-snapshot-path snapshot))
