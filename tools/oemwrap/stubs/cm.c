typedef unsigned long size_t; struct camera_metadata; typedef struct camera_metadata camera_metadata_t;
camera_metadata_t *allocate_camera_metadata(size_t a,size_t b){return 0;} void free_camera_metadata(camera_metadata_t*m){}
int append_camera_metadata(camera_metadata_t*d,const camera_metadata_t*s){return 0;} int add_camera_metadata_entry(camera_metadata_t*m,unsigned t,const void*d,size_t c){return 0;}
int find_camera_metadata_ro_entry(const camera_metadata_t*m,unsigned t,void*e){return 0;} size_t get_camera_metadata_entry_count(const camera_metadata_t*m){return 0;} size_t get_camera_metadata_data_count(const camera_metadata_t*m){return 0;}
int get_camera_metadata_tag_type(unsigned t){return 0;} int set_camera_metadata_vendor_ops(const void*o){return 0;}
int find_camera_metadata_entry(camera_metadata_t*m,unsigned t,void*e){return 0;} camera_metadata_t *clone_camera_metadata(const camera_metadata_t*s){return 0;}
int get_camera_metadata_ro_entry(const camera_metadata_t*m,size_t i,void*e){return 0;}
