#lang racket

;;; edit-tui-rebuild/command/key.rkt —— 键 token = 标签 + 原始字节
;;;
;;; 输入的中间状态不做 char / symbol 解码，token 就是终端给的那一份：
;;;
;;;   (key-token tag bytes)
;;;     tag   : 终端事件类型
;;;             'key（单字节）| 'ctrl | 'alt | 'utf8 | 'mod-seq（CSI 带修饰）
;;;             | 命名键 'up 'down 'left 'right 'home 'end
;;;               'insert 'del 'pageup 'pagedown 'backtab
;;;     bytes : 原始字节
;;;
;;; 绑定也用同一种表示：`key` 把 (key 'x 'ctrl) 编码成 ('ctrl . #"\x18")。
;;; 于是「事件 → 命中」是一次字节比较；插入时把 bytes 原样交给 buffer
;;; 解码一次（document 是字符串，这一次解码省不掉）。
;;;
;;; 命名键有不止一种终端写法（CSI / SS3 / 老式 ~）。raw-key-token 按 tag
;;; 归一成一种规范字节，所以一张表里每个绑定只存一条。
;;;
;;; 终端不能区分的组合会共用 token（这就是事实，不是 bug）：
;;;   C-i = Tab      C-m = Enter     C-[ = Escape
;;;   C-h = Backspace  C-j = Enter
;;; 想真正区分它们需要 kitty keyboard protocol / xterm modifyOtherKeys。

(provide (struct-out key-token)
         key key? key-tag key-bytes key=?
         key->string key-text
         raw-key-token
         normalize-mods
         mods-order)

;;; ════════════════ 类型 ════════════════

(struct key-token (tag bytes) #:transparent)

(define (key? x) (key-token? x))
(define key-tag key-token-tag)
(define key-bytes key-token-bytes)
(define (key=? a b) (equal? a b))

(define mods-order '(ctrl alt shift))

(define (normalize-mods mods)
  (for/list ([m (in-list mods-order)] #:when (memq m mods)) m))

;;; ════════════════ ANSI 编码表 ════════════════
;;;
;;; final 类：ESC [ 1 ; code X        （方向键 / Home / End）
;;; tilde 类：ESC [ base ; code ~     （Insert / Delete / PageUp / PageDown）

(define named-keys
  '((up       final 65)   ; A
    (down     final 66)   ; B
    (right    final 67)   ; C
    (left     final 68)   ; D
    (home     final 72)   ; H
    (end      final 70)   ; F
    (insert   tilde 2)
    (del      tilde 3)
    (pageup   tilde 5)
    (pagedown tilde 6)
    (backtab  final 90))) ; Z

;; tui raw 事件类型里的命名键（raw-key-token 用）
(define raw-named-tags
  '(up down left right home end insert del pageup pagedown backtab))

(define (raw-named? tag)
  (and (memq tag raw-named-tags) #t))

(define (number-bytes n)
  (string->bytes/utf-8 (number->string n)))

(define (named-canonical kind code)
  (case kind
    [(final) (bytes-append #"\e[" (bytes code))]
    [(tilde) (bytes-append #"\e[" (number-bytes code) #"~")]
    [else (error 'named-canonical "未知 kind：~a" kind)]))

(define (modifier-code mods)
  (+ 1
     (if (memq 'shift mods) 1 0)
     (if (memq 'alt mods) 2 0)
     (if (memq 'ctrl mods) 4 0)))

(define (named-modified kind base mods)
  (define code (modifier-code mods))
  (case kind
    [(final)
     (bytes-append #"\e[1;" (number-bytes code) (bytes base))]
    [(tilde)
     (bytes-append #"\e[" (number-bytes base) #";" (number-bytes code) #"~")]
    [else (error 'named-modified "未知 kind：~a" kind)]))

;;; ════════════════ 字节规范化 ════════════════
;;;
;;; 终端对同一个物理键可能送不同字节：
;;;   8 (BS) 与 127 (DEL) 都是 Backspace；10 (LF) 与 13 (CR) 都是 Enter。
;;; 归一成一种，免得绑定漏写法。

(define (canonical-byte b)
  (case b
    [(8) 127]
    [(10) 13]
    [else b]))

;; tui 的字节分类：1..26 里排除特殊键后才是 'ctrl
(define (ctrl-tag b)
  (if (and (<= 1 b 26) (not (memv b '(8 9 10 13 27)))) 'ctrl 'key))

;;; ════════════════ 绑定 -> (tag . bytes) ════════════════

(define (char-byte c)
  (define n (char->integer c))
  (and (< n 128) n))

(define (char-bytes c)
  (define b (char-byte c))
  (if b (bytes b) (string->bytes/utf-8 (string c))))

;; Ctrl 组合 -> 控制字节（终端标准映射）；无法表达 -> #f
(define (ctrl-byte-of c)
  (define n (char->integer c))
  (cond
    [(char=? c #\?) 127]
    [(<= n 127) (bitwise-and n #x1F)]
    [else #f]))

(define (encode-char c mods)
  (define ctrl? (memq 'ctrl mods))
  (define alt? (memq 'alt mods))
  ;; shift 不参与字符键编码：终端直接送大小写字符（'A' 就是 shift+a）。
  ;; 只有命名键的 shift 才进 CSI 修饰位。
  (cond
    [ctrl?
     (define b (ctrl-byte-of c))
     (cond
       [(not b) (error 'key "Ctrl 组合没有字节编码：~a" c)]
       [alt? (key-token 'mod-seq (bytes-append #"\e" (bytes b)))]
       [else (key-token (ctrl-tag b) (bytes (canonical-byte b)))])]
    [alt?
     (key-token 'alt (bytes-append #"\e" (char-bytes c)))]
    [else
     (define b (char-byte c))
     (cond
       [(not b) (key-token 'utf8 (string->bytes/utf-8 (string c)))]
       [(or (< b 32) (= b 127))
        (key-token (ctrl-tag b) (bytes (canonical-byte b)))]
       [else (key-token 'key (bytes b))])]))

(define (encode-named name mods)
  (define info (assq name named-keys))
  (cond
    [(not info) (error 'key "未知命名键：~a" name)]
    [else
     (define kind (cadr info))
     (define base (caddr info))
     (cond
       [(null? mods) (key-token name (named-canonical kind base))]
       [(eq? name 'backtab) (error 'key "Backtab 不能带修饰键")]
       [else (key-token 'mod-seq (named-modified kind base mods))])]))

(define (normalize-name n)
  (case n
    [(delete) 'del]
    [else n]))

(define (encode-symbol name mods)
  (define n (normalize-name name))
  (cond
    [(eq? n 'space) (encode-char #\space mods)]
    [(eq? n 'backspace)
     (if (null? mods)
         (key-token 'key #"\x7f")
         (error 'key "Backspace 不能带修饰键"))]
    [(eq? n 'escape)
     (if (null? mods)
         (key-token 'key #"\e")
         (error 'key "Escape 不能带修饰键"))]
    [(eq? n 'enter)
     (if (null? mods)
         (key-token 'key #"\r")
         (error 'key "Enter 不能带修饰键"))]
    [(eq? n 'tab)
     (cond
       [(null? mods) (key-token 'key #"\t")]
       [(equal? mods '(shift)) (key-token 'backtab #"\e[Z")]
       [else (error 'key "Tab 只能带 Shift（= Backtab）")])]
    [(assq n named-keys) (encode-named n mods)]
    [else
     ;; 1 字符 symbol 当字符键：'a 'A '! '中 …
     (define s (symbol->string n))
     (if (= 1 (string-length s))
         (encode-char (string-ref s 0) mods)
         (error 'key "未知键名：~a" name))]))

(define (key name . mods)
  (define m (normalize-mods mods))
  (cond
    [(char? name) (encode-char name m)]
    [(symbol? name) (encode-symbol name m)]
    [else (error 'key "键名要是 symbol 或 char：~a" name)]))

;;; ════════════════ tui raw 事件 -> token ════════════════
;;;
;;; tui 的 read-event/raw 给 (values type data mods)：
;;;   type : 'key 'ctrl 'alt 'utf8 'mod-seq 'up 'down … 'mouse 'paste 'resize
;;;   data : 原始字节（mouse/paste/resize 除外）
;;;
;;; 命名键按 tag 归一（CSI / SS3 / 老式 ~ 都变成一种写法）；
;;; 其余原样保留字节。

;;; 热路径缓存：单字节键和命名键的 token 在建表时全部建好，
;;; 打字时 raw-key-token 只查表 / 查向量，不分配。
(define byte-tokens
  (for/vector ([b (in-range 128)])
    (key-token (ctrl-tag b) (bytes (canonical-byte b)))))

(define named-tokens
  (for/hash ([tag (in-list raw-named-tags)])
    (define info (assq tag named-keys))
    (values tag (key-token tag (named-canonical (cadr info) (caddr info))))))

(define (raw-key-token tag data)
  (cond
    [(raw-named? tag) (hash-ref named-tokens tag)]
    [(eq? tag 'key)
     (if (and (bytes? data) (= 1 (bytes-length data)))
         (vector-ref byte-tokens (bytes-ref data 0))
         (key-token 'key data))]
    [else (key-token tag data)]))

;;; ════════════════ 显示 / 文本 ════════════════

(define named-labels
  '((up . "Up") (down . "Down") (left . "Left") (right . "Right")
    (home . "Home") (end . "End") (insert . "Insert") (del . "Delete")
    (pageup . "PageUp") (pagedown . "PageDown") (backtab . "Backtab")))

(define (byte->display b)
  (case b
    [(0) "C-Space"]
    [(9) "Tab"]
    [(13) "Enter"]
    [(27) "Escape"]
    [(127) "Backspace"]
    [(32) "Space"]
    [else
     (cond
       [(<= 33 b 126) (string (integer->char b))]
       [(<= 1 b 26) (format "C-~a" (char-downcase (integer->char (+ 64 b))))]
       [else (format "\\x~a" b)])]))

;; ESC [ params final -> (list params final) | #f
(define (parse-csi bs)
  (and (>= (bytes-length bs) 3)
       (= (bytes-ref bs 0) 27)
       (= (bytes-ref bs 1) 91)
       (let loop ([i 2] [cur #f] [acc '()])
         (define b (bytes-ref bs i))
         (cond
           [(= i (sub1 (bytes-length bs)))
            (list (if cur (append acc (list cur)) acc) b)]
           [(= b 59)                             ; ;
            (loop (add1 i) #f (append acc (list (or cur 0))))]
           [(<= 48 b 57)                         ; 0-9
            (loop (add1 i) (+ (* (or cur 0) 10) (- b 48)) acc)]
           [else (loop (add1 i) cur acc)]))))

(define (csi-key-name ps final)
  (cond
    [(= final 126)                              ; ~
     (case (and (pair? ps) (car ps))
       [(1 7) "Home"] [(4 8) "End"] [(2) "Insert"] [(3) "Delete"]
       [(5) "PageUp"] [(6) "PageDown"]
       [else "~"])]
    [else
     (case final
       [(65) "Up"] [(66) "Down"] [(67) "Right"] [(68) "Left"]
       [(72) "Home"] [(70) "End"] [(90) "Backtab"]
       [else (string (integer->char final))])]))

(define (mod-prefix code)
  (define m (if (and code (<= 2 code 8)) (- code 1) 0))
  (string-append
   (if (bitwise-bit-set? m 2) "C-" "")
   (if (bitwise-bit-set? m 1) "M-" "")
   (if (bitwise-bit-set? m 0) "S-" "")))

(define (mod-seq->string bs)
  (define csi (parse-csi bs))
  (cond
    [csi
     (define ps (car csi))
     (define final (cadr csi))
     (define code (and (>= (length ps) 2) (cadr ps)))
     (string-append (mod-prefix code) (csi-key-name ps final))]
    [(and (= (bytes-length bs) 2) (= (bytes-ref bs 0) 27))
     ;; ESC + 控制字节 = Ctrl+Alt+字母
     (define b (bytes-ref bs 1))
     (if (<= 1 b 26)
         (format "C-M-~a" (char-downcase (integer->char (+ 64 b))))
         (format "M-~a" (byte->display b)))]
    [else (format "mod-seq:~s" bs)]))

(define (key->string k)
  (define tag (key-tag k))
  (define bs (key-bytes k))
  (case tag
    [(key) (byte->display (bytes-ref bs 0))]
    [(ctrl) (format "C-~a" (char-downcase (integer->char (+ 64 (bytes-ref bs 0)))))]
    [(alt) (format "M-~a" (bytes->string/utf-8 (subbytes bs 1) (integer->char 65533)))]
    [(utf8) (bytes->string/utf-8 bs (integer->char 65533))]
    [(mod-seq) (mod-seq->string bs)]
    [(seq) (format "seq:~s" bs)]
    [else (cond [(assq tag named-labels) => cdr] [else (format "~a" tag)])]))

;; 字符键 -> 1 字符文本（可打印才返回）。document 是字符串，插入要解一次码。
(define (key-text k)
  (define tag (key-tag k))
  (case tag
    [(key)
     (define bs (key-bytes k))
     (and (= 1 (bytes-length bs))
          (let ([b (bytes-ref bs 0)])
            (and (<= 32 b 126) (string (integer->char b)))))]
    [(utf8) (bytes->string/utf-8 (key-bytes k))]
    [else #f]))
