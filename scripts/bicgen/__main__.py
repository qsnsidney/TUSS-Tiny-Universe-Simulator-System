from . import translation

# IC Data
# https://nbody.shop/data.html

# in_tipsy_file_path = './data/tipsy/LOW/LOW.bin'
in_tipsy_file_path = None
print('Info:', 'Loading from tipsy', in_tipsy_file_path)
out_bin_file_path = './tmp/tipsy/0.bin'
print('Info:', 'Writing into bin', out_bin_file_path)
translation.from_tipsy_into_bin(
    in_tipsy_file_path=in_tipsy_file_path, out_bin_file_path=out_bin_file_path)
